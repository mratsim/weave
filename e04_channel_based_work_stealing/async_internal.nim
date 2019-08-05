import
  # Standard library
  macros, typetraits,
  # Internal
  ./tasking_internal, ./task,
  ./profile, ./runtime

# TODO:
# overload with loop bounds for task splitting

macro async(funcCall: typed): untyped =
  # We take typed argument so that overloading resolution
  # is already done and arguments are semchecked
  funcCall.expectKind(nnkCall)
  result = newStmtList()

  # Get a serialized type and data for all function arguments
  # We use adhoc tuple
  var argsTy = nnkPar.newTree()
  var args = nnkPar.newTree()
  for i in 1 ..< funcCall.len:
    argsTy.add getTypeInst(funcCall[i])
    args.add funcCall[i]

  # Check that the type are safely serializable
  let fn = funcCall[0]
  let fnName = $fn
  result.add quote do:
    static:
      assert `argsTy`.supportsCopyMem, "\n\n" & `fnName` &
        " has arguments managed by GC (ref/seq/strings),\n" &
        "  they cannot be distributed across threads.\n" &
        "  Argument types: " & `argsTy`.name & "\n\n"

      assert sizeof(`argsTy`) <= TaskDataSize, "\n\n" & `fnName` &
        " has arguments that do not fit in the async data buffer.\n" &
        "  Argument types: " & `argsTy`.name & "\n" &
        "  Current size: " & $sizeof(`argsTy`) & "\n" &
        "  Maximum size allowed: " & $TaskDataSize & "\n\n"

  # Create the async function
  let async_fn = ident("async_" & fnName)
  let param = ident("param") # type-erased pointer to data
  let data = ident("data")   # typed pointer to data
  var fnCall = newCall(fn)
  for i in 1 ..< funcCall.len:
    fnCall.add nnkBracketExpr.newTree(
      data,
      newLit i-1
    )
  result.add quote do:
    proc `async_fn`(param: pointer) {.nimcall.} =
      let this = get_current_task()
      assert not is_root_task(this)

      let `data` = cast[ptr `argsTy`](param) # TODO - restrict
      `fnCall`

  # Create the task
  result.add quote do:
    profile(enq_deq_task):
      let task = task_alloc()
      task.parent = get_current_task()
      task.fn = `async_fn`
      cast[ptr `argsTy`](task.data.addr)[] = `args`
      push task

  # echo result.toStrLit
