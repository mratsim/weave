import
  # Standard library
  macros, typetraits,
  # Internal
  ./tasking_internal, ./task,
  ./future_internal,
  ./profile, ./runtime

# TODO: autocreate a closure either via:
#
# async_for i in 0 .. 10:
#   A(i)
#   B(i)
#   C(i)
#
# or
#
# for i in async(0..10):
#   A(i)
#   B(i)
#   C(i)

template forEach*(idx: untyped{ident}, body: untyped): untyped =
  ## To be called within a loop task
  ## Gets the loop bounds and iterate the over them
  ## Also poll steal requests in-between iterations
  let this = get_current_task()
  assert this.is_loop
  assert this.start == this.cur
  var idx {.inject.} = this.start
  inc this.cur
  while idx < this.stop:
    body
    inc idx
    inc this.cur
    RT_check_for_steal_requests()

macro async_for*(
        s: Slice,
        funcCall: typed{call}
      ): untyped =
  ## Inputs:
  ##   - The iterator index
  ##   - A slice denoting its low to high range
  ##   - a function call that must return void.
  ##
  ## Note: The function definition should use the
  ##       `forEach` template

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

  # Check that the type are safely serializable
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
      let this = get_current_task()
      assert not is_root_task(this)

      when bool(`withArgs`):
        let `data` = cast[ptr `argsTy`](param) # TODO - restrict
      `fnCall`
  # Create the task
  let prof = bindSym("profile")
  result.add quote do:
    prof(enq_deq_task):
      let task = task_alloc()
      task.parent = get_current_task()
      task.fn = `async_fn`
      task.is_loop = true
      task.start = `s`.a
      task.cur = `s`.a
      task.stop = `s`.b
      task.chunks = max(1, abs(`s`.b - `s`.a) div num_workers)
      task.sst = 1
      when bool(`withArgs`):
        cast[ptr `argsTy`](task.data.addr)[] = `args`
      push task


when isMainModule:
  import ./tasking, ./primitives/c

  template log(args: varargs[untyped]): untyped =
    printf(args)
    flushFile(stdout)

  block: # Async without result

    proc display_range() =
      forEach(i):
        log("%d (thread %d)\n", i, ID)
      log("Thread %d - SUCCESS\n", ID)

    proc main() =
      tasking_init()

      async_for 0..100, display_range()

      tasking_barrier()
      tasking_exit()

    main()
