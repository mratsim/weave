import
  # Standard library
  macros, typetraits,
  # Internal
  ./scheduler, ./runtime, ./contexts,
  ./datatypes/sync_types,
  ./instrumentation/[contracts, profilers]

when not compileOption("threads"):
  {.error: "This requires --threads:on compilation flag".}

template parallelForWrapper(idx: untyped{ident}, body: untyped): untyped =
  ## To be called within a loop task
  ## Gets the loop bounds and iterate the over them
  ## Also poll steal requests in-between iterations
  let this = myTask()
  ascertain: this.isLoop
  ascertain: this.start == this.cur

  var idx {.inject.} = this.start
  inc this.cur
  while idx < this.stop:
    body
    idx += this.stride
    this.cur += this.stride
    loadBalance(Weave)

macro parallelForImpl(loopParams: untyped, stride: int, body: untyped): untyped =
  ## Parallel for loop
  ## Syntax:
  ##
  ## parallelFor i in 0 ..< 10:
  ##   echo(i)
  ##
  ## Variables from the external scope needs to be explicitly captured
  ##
  ##  var a = 100
  ##  var b = 10
  ##  parallelFor i in 0 ..< 10:
  ##    captures: {a, b}
  ##    echo a + b + i

  result = newStmtList()

  # Checks
  # --------------------------------------------------------
  # looParams should have the form "i in 0..<10"
  loopParams.expectKind(nnkInfix)
  assert loopParams[0].eqIdent"in"
  loopParams[1].expectKind(nnkIdent)
  loopParams[2].expectKind(nnkInfix) # 0 ..< 10 / 0 .. 10, for now we don't support slice objects
  assert loopParams[2][0].eqIdent".." or loopParams[2][0].eqIdent"..<"

  # Extract loop parameters
  # --------------------------------------------------------

  let idx = loopParams[1]
  let start = loopParams[2][1]
  var stop = loopParams[2][2]
  # We use exclusive bounds
  if loopParams[2][0].eqIdent"..":
    stop = newCall(ident"+", stop, newLit(1))

  # Extract captured variables
  # --------------------------------------------------------
  body.expectKind(nnkStmtList)

  # parallelFor i in 0 ..< 10:
  #   captures: a
  #   ...
  #
  # StmtList
  #   Call
  #     Ident "captures"
  #     StmtList
  #       Ident "a"
  #   Rest of the body

  var captured = nnkPar.newTree()
  var capturedTy = nnkPar.newTree()

  if body[0].kind == nnkCall and body[0][0].eqIdent"captures":
    body[0][1].expectKind(nnkStmtList)
    body[0][1][0].expectKind(nnkCurly)
    for i in 0 ..< body[0][1][0].len:
      captured.add body[0][1][0][i]
      capturedTy.add newCall(ident"typeof", body[0][1][0][i])

    # Remove the captures section
    body[0] = nnkDiscardStmt.newTree(body[0].toStrLit)

  let CapturedTy = ident"CapturedTy"
  if capturedTy.len > 0:
    result.add quote do:
      type `CapturedTy` = `capturedTy`

  # Package the body in a proc
  # --------------------------------------------------------
  var params = @[newEmptyNode()] # for loops have no return value
  for i in 0 ..< captured.len:
    params.add newIdentDefs(
                 captured[i],
                 capturedTy[i]
               )

  let pragmas = nnkPragma.newTree(
                  ident"nimcall",
                  ident"gcsafe"
                )
  var procBody = newStmtList()
  procBody.add newCall(
    bindSym"parallelForWrapper",
    idx, body
  )

  let parForName = ident"parallelForSection"
  let parForSection = newProc(
    name = parForName,
    params = params,
    body = procBody,
    pragmas = pragmas
  )

  # Sanity checks
  # --------------------------------------------------------
  if captured.len > 0:
    result.add quote do:
      static:
        doAssert supportsCopyMem(`CapturedTy`), "\n\n parallelFor" &
          " has arguments managed by GC (ref/seq/strings),\n" &
          "  they cannot be distributed across threads.\n" &
          "  Argument types: " & $`CapturedTy` & "\n\n"

        doAssert sizeof(`CapturedTy`) <= TaskDataSize, "\n\n parallelFor" &
          " has arguments that do not fit in the parallel tasks data buffer.\n" &
          "  Argument types: " & `CapturedTy`.name & "\n" &
          "  Current size: " & $sizeof(`CapturedTy`) & "\n" &
          "  Maximum size allowed: " & $TaskDataSize & "\n\n"

  # Create the closure environment
  # --------------------------------------------------------
  var fnCall = newCall(parForName)
  let data = ident("data") # typed pointer to data

  if captured.len == 1:
    # With only 1 arg, the tuple syntax doesn't construct a tuple
    # let data = (123) is an int
    fnCall.add nnkDerefExpr.newTree(data)
  else: # This handles the 0 argument case as well
    for i in 0 ..< captured.len:
      fnCall.add nnkBracketExpr.newTree(
        data, newLit i
      )

  # Declare the proc that packages the loop body
  # --------------------------------------------------------
  result.add parForSection

  # Create the async function (that calls the proc that packages the loop body)
  # --------------------------------------------------------
  let async_fn = ident("weaveParallelFor")
  let withArgs = captured.len > 0

  result.add quote do:
    proc `async_fn`(param: pointer) {.nimcall.} =
      let this = myTask()
      assert not isRootTask(this)

      when bool(`withArgs`):
        let `data` = cast[ptr `CapturedTy`](param)
      `fnCall`

  # Create the task
  # --------------------------------------------------------
  result.add quote do:
    profile(enq_deq_task):
      let task = newTaskFromCache()
      task.parent = myTask()
      task.fn = `async_fn`
      task.isLoop = true
      task.start = `start`
      task.cur = `start`
      task.stop = `stop`
      task.stride = `stride`
      when bool(`withArgs`):
        cast[ptr `CapturedTy`](task.data.addr)[] = `captured`
      schedule(task)

template parallelFor*(loopParams: untyped, body: untyped): untyped =
  parallelForImpl(loopParams, stride = 1, body)

template parallelForStrided*(loopParams: untyped, stride: Positive, body: untyped): untyped =
  parallelForImpl(loopParams, stride, body)

when isMainModule:
  import ./instrumentation/loggers

  block:
    proc main() =
      init(Weave)

      parallelFor i in 0 ..< 100:
        log("%d (thread %d)\n", i, myID())

      exit(Weave)

    echo "Simple parallel for"
    echo "-------------------------"
    # main()
    echo "-------------------------"

  block: # Capturing outside scope
    proc main2() =
      init(Weave)

      var a = 100
      var b = 10
      parallelFor i in 0 ..< 10:
        captures: {a, b}
        log("a+b+i = %d (thread %d)\n", a+i, myID())

      exit(Weave)


    echo "\n\nCapturing outside variables"
    echo "-------------------------"
    # main2()
    echo "-------------------------"


  block: # Nested loops
    proc main3() =
      init(Weave)

      parallelFor i in 0 ..< 4:
        parallelFor j in 0 ..< 8:
          captures: {i}
          log("Matrix[%d, %d] (thread %d)\n", i, j, myID())

      exit(Weave)

    echo "\n\nNested loops"
    echo "-------------------------"
    # main3()
    echo "-------------------------"


  block: # Strided Nested loops
    proc main4() =
      init(Weave)

      parallelForStrided i in 0 ..< 100, stride = 30:
        parallelForStrided j in 0 ..< 200, stride = 60:
          captures: {i}
          log("Matrix[%d, %d] (thread %d)\n", i, j, myID())

      exit(Weave)

    echo "\n\nStrided Nested loops"
    echo "-------------------------"
    main4()
    echo "-------------------------"
