import
  # Standard library
  macros, typetraits,
  # Internal
  ./scheduler, ./runtime, ./contexts,
  ./datatypes/[flowvars, sync_types],
  ./instrumentation/[contracts, profilers]

macro spawn*(funcCall: typed): untyped =
  # We take typed argument so that overloading resolution
  # is already done and arguments are semchecked
  funcCall.expectKind(nnkCall)
  result = newStmtList()

  # Get the return type if any
  let retType = funcCall[0].getImpl[3][0]
  let needFuture = retType.kind != nnkEmpty

  # Get a serialized type and data for all function arguments
  # We use adhoc tuple
  var argsTy = nnkPar.newTree()
  var args = nnkPar.newTree()
  for i in 1 ..< funcCall.len:
    argsTy.add getTypeInst(funcCall[i])
    args.add funcCall[i]

  # Check that the type is safely serializable
  # TODO: we need to check the return type as well
  #       so we can merge both future and no future code path
  let fn = funcCall[0]
  let fnName = $fn
  let withArgs = args.len > 0
  if withArgs:
    result.add quote do:
      static:
        assert supportsCopyMem(`argsTy`), "\n\n" & `fnName` &
          " has arguments managed by GC (ref/seq/strings),\n" &
          "  they cannot be distributed across threads.\n" &
          "  Argument types: " & $`argsTy` & "\n\n"

        assert sizeof(`argsTy`) <= TaskDataSize, "\n\n" & `fnName` &
          " has arguments that do not fit in the async data buffer.\n" &
          "  Argument types: " & `argsTy`.name & "\n" &
          "  Current size: " & $sizeof(`argsTy`) & "\n" &
          "  Maximum size allowed: " & $TaskDataSize & "\n\n"

  # Create the async function
  let async_fn = ident("async_" & fnName)
  var fnCall = newCall(fn)
  let data = ident("data")   # typed pointer to data

  if not needFuture: # TODO: allow awaiting on a Flowvar[void]
    if funcCall.len == 2:
      # With only 1 arg, the tuple syntax doesn't construct a tuple
      # let data = (123) # is an int
      fnCall.add nnkDerefExpr.newTree(data)
    else: # This handles the 0 arg case as well
      for i in 1 ..< funcCall.len:
        fnCall.add nnkBracketExpr.newTree(
          data,
          newLit i-1
        )

    # Create the async call
    result.add quote do:
      proc `async_fn`(param: pointer) {.nimcall.} =
        preCondition: not myTask().isRootTask()

        when bool(`withArgs`):
          let `data` = cast[ptr `argsTy`](param) # TODO - restrict
        `fnCall`
    # Create the task
    result.add quote do:
      profile(enq_deq_task):
        let task = newTaskFromCache()
        task.parent = myTask()
        task.fn = `async_fn`
        when bool(`withArgs`):
          cast[ptr `argsTy`](task.data.addr)[] = `args`
        schedule(task)

  else: ################ Need a future
    # We repack fut + args.
    let fut = ident("fut")

    # data[0] will be the future.

    var futArgs = nnkPar.newTree
    var futArgsTy = nnkPar.newTree
    futArgs.add fut
    futArgsTy.add nnkBracketExpr.newTree(
      bindSym"FlowVar",
      retType
    )
    for i in 1 ..< funcCall.len:
      futArgsTy.add getTypeInst(funcCall[i])
      futArgs.add funcCall[i]

    for i in 1 ..< funcCall.len:
      fnCall.add nnkBracketExpr.newTree(
        data,
        newLit i
      )

    result.add quote do:
      proc `async_fn`(param: pointer) {.nimcall.} =
        preCondition: not myTask().isRootTask()

        let `data` = cast[ptr `futArgsTy`](param) # TODO - restrict
        let res = `fnCall`
        `data`[0].setWith(res)

    # Create the task
    let freshIdent = ident($retType)
    result.add quote do:
      profile(enq_deq_task):
        let task = newTaskFromCache()
        task.parent = myTask()
        task.fn = `async_fn`
        task.has_future = true
        let `fut` = newFlowvar(`freshIdent`)
        cast[ptr `futArgsTy`](task.data.addr)[] = `futArgs`
        schedule(task)

      # Return the future
      `fut`

  # Wrap in a block for namespacing
  result = nnkBlockStmt.newTree(newEmptyNode(), result)
  # echo result.toStrLit

proc sync*[T](fv: FlowVar[T]): T =
  fv.forwardTo(result)

when isMainModule:
  block: # Async without result

    proc display_int(x: int) =
      stdout.write(x)
      stdout.write(" - SUCCESS\n")

    proc main() =
      init(Runtime)

      spawn display_int(123456)
      spawn display_int(654321)

      sync(Runtime)
      exit(Runtime)

    # main()

  block: # Async/Await

    proc async_fib(n: int): int =

      if n < 2:
        return n

      let x = spawn async_fib(n-1)
      let y = async_fib(n-2)

      result = sync(x) + y

    proc main2() =

      init(Runtime)

      let f = async_fib(10)

      sync(Runtime)
      exit(Runtime)

      echo f

    main2()
