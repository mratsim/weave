import
  # Standard library
  macros, typetraits,
  # Internal
  ./scheduler, ./runtime, ./contexts,
  ./datatypes/[flowvars, sync_types],
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

macro parallelFor*(loopParams: untyped, body: untyped): untyped =

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
    for i in 0 ..< body[0][1].len:
      captured.add body[0][1][i]
      capturedTy.add newCall(ident"typeof", body[0][1][i])

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
  result = newStmtList()
  if captured.len > 0:
    result.add quote do:
      static:
        doAssert supportsCopyMem(`capturedTy`), "\n\n parallelFor" &
          " has arguments managed by GC (ref/seq/strings),\n" &
          "  they cannot be distributed across threads.\n" &
          "  Argument types: " & $`capturedTy` & "\n\n"

        doAssert sizeof(`capturedTy`) <= TaskDataSize, "\n\n parallelFor" &
          " has arguments that do not fit in the parallel tasks data buffer.\n" &
          "  Argument types: " & `capturedTy`.name & "\n" &
          "  Current size: " & $sizeof(`capturedTy`) & "\n" &
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
        let `data` = cast[`capturedTy`](param)
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
      task.stride = 1
      when bool(`withArgs`):
        cast[ptr `capturedTy`](task.data.addr)[] = `captured`
      schedule(task)


  echo result.toStrLit

when isMainModule:
  import ./instrumentation/loggers

  block: # Async without result
    proc main() =
      init(Weave)

      parallelFor i in 0 ..< 100:
        log("%d (thread %d)\n", i, myID())

      sync(Weave)
      exit(Weave)

    main()
