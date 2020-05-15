# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# A job is processing request submitted from outside a Weave worker thread
# They are scheduled in FIFO order and minimize latency for submitters.
# In particular, it is optimized for jobs assumed independent.

# Job submission
# ----------------------------------------------------------------------------------

import
  # Standard library
  macros, typetraits, atomics, os,
  # Internal
  ./memory/[allocs, memory_pools],
  ./scheduler, ./contexts,
  ./datatypes/[flowvars, sync_types],
  ./instrumentation/contracts,
  ./cross_thread_com/[pledges, channels_mpsc_unbounded_batch, event_notifiers],
  ./state_machines/sync_root,
  ./executor

proc submitImpl(pledges: NimNode, funcCall: NimNode): NimNode =
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
        # assert supportsCopyMem(`argsTy`), "\n\n" & `fnName` &
        #   " has arguments managed by GC (ref/seq/strings),\n" &
        #   "  they cannot be distributed across threads.\n" &
        #   "  Argument types: " & $`argsTy` & "\n\n"

        assert sizeof(`argsTy`) <= TaskDataSize, "\n\n" & `fnName` &
          " has arguments that do not fit in the async data buffer.\n" &
          "  Argument types: " & `argsTy`.name & "\n" &
          "  Current size: " & $sizeof(`argsTy`) & "\n" &
          "  Maximum size allowed: " & $TaskDataSize & "\n\n"

  # Create the async function
  let async_fn = ident("async_" & fnName)
  var fnCall = newCall(fn)
  let data = ident("data")   # typed pointer to data

  # Submit immediately or delay on dependencies
  var submitBlock: NimNode
  let job = ident"job"
  if pledges.isNil:
    submitBlock = newCall(bindSym"submitJob", job)
  elif pledges.len == 1:
    let pledgeDesc = pledges[0]
    if pledgeDesc.kind in {nnkIdent, nnkSym}:
      submitBlock = quote do:
        if not delayedUntil(cast[Task](`job`), `pledgeDesc`, jobProviderContext.mempool):
          submitJob(`job`)
    else:
      pledgeDesc.expectKind({nnkPar, nnkTupleConstr})
      let pledge = pledgeDesc[0]
      let pledgeIndex = pledgeDesc[1]
      submitBlock = quote do:
        if not delayedUntil(cast[Task](`job`), `pledge`, int32(`pledgeIndex`), myMemPool()):
          submitJob(`job`)
  else:
    let delayedMulti = quote do:
      delayedUntilMulti(cast[Task](`job`), jobProviderContext.mempool, `pledges`)
    submitBlock = quote do:
      if not `delayedMulti`:
        submitJob(`job`)

  if not needFuture: # TODO: allow awaiting on a Pending[void]
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
        preCondition: not isRootTask(myTask())

        when bool(`withArgs`):
          let `data` = cast[ptr `argsTy`](param) # TODO - restrict
        `fnCall`
    # Create the task
    result.add quote do:
      when defined(WV_profile):
        # TODO - add timers for jobs
        discard timer_start(timer_enq_deq_job)
      block enq_deq_job:
        let `job` = jobProviderContext.mempool[].borrow(deref(Job))
        `job`.parent = jobProviderContext.addr # By convention, we set the parent to the JobProvider address
        `job`.fn = `async_fn`
        # registerDescendant(mySyncScope()) # TODO: does it make sense?
        # `task`.scopedBarrier = mySyncScope()
        when bool(`withArgs`):
          cast[ptr `argsTy`](`job`.data.addr)[] = `args`
        `submitBlock`

        manager.jobNotifier[].notify() # Wake up the runtime
      when defined(WV_profile):
        timer_stop(timer_enq_deq_job)

  else: ################ Need a future
    # We repack fut + args.
    let fut = ident("fut")

    # data[0] will be the future.

    var futArgs = nnkPar.newTree
    var futArgsTy = nnkPar.newTree
    futArgs.add fut
    futArgsTy.add nnkBracketExpr.newTree(
      bindSym"Pending",
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
        preCondition: not isRootTask(myTask())

        let `data` = cast[ptr `futArgsTy`](param) # TODO - restrict
        let res = `fnCall`
        readyWith(`data`[0], res)

    # Create the task
    let freshIdent = ident($retType)
    result.add quote do:
      when defined(WV_profile):
        # TODO profiling templates visibility issue
        discard timer_start(timer_enq_deq_job)
      block enq_deq_task:
        let `job` = jobProviderContext.mempool[].borrow(deref(Job))
        `job`.parent = jobProviderContext.addr # By convention, we set the parent to the JobProvider address
        `job`.fn = `async_fn`
        # registerDescendant(mySyncScope()) # TODO: does it make sense?
        # `task`.scopedBarrier = mySyncScope()
        `job`.has_future = true
        `job`.futureSize = uint8(sizeof(`retType`))
        let `fut` = newPending(jobProviderContext.mempool[], `freshIdent`)
        cast[ptr `futArgsTy`](`job`.data.addr)[] = `futArgs`
        `submitBlock`

        manager.jobNotifier[].notify() # Wake up the runtime
        when defined(WV_profile):
          discard timer_stop(timer_enq_deq_job)
        # Return the future
        `fut`

  # Wrap in a block for namespacing
  result = nnkBlockStmt.newTree(newEmptyNode(), result)
  # echo result.toStrLit

macro submit*(fnCall: typed): untyped =
  ## Submit the input function call asynchronously to the Weave runtime.
  ##
  ## This is a compatibility routine for foreign threads.
  ## `setupJobProvider` MUST be called on the submitter thread beforehand
  ##
  ## This procedure is intended for interoperability with long-running threads
  ## started with `createThread`
  ## and other threadpools and/or execution engines,
  ## use `spawn` otherwise.
  ##
  ## If the function calls returns a result, submit will wrap it in a Pending[T].
  ## You can use `settle` to block the current thread and extract the asynchronous result from the Pending[T].
  ## You can use `isReady` to check if result is available and if subsequent
  ## `settle` calls would block or return immediately.
  ##
  ## `submit` returns immediately.
  ##
  ## Jobs are processed approximately in First-In-First-Out (FIFO) order.
  result = submitImpl(nil, fnCall)

macro submitDelayed*(pledges: varargs[typed], fnCall: typed): untyped =
  ## Submit the input function call asynchronously to the Weave runtime.
  ## The function call will only be scheduled when the pledge is fulfilled.
  ##
  ## This is a compatibility routine for foreign threads.
  ## `setupJobProvider` MUST be called on the submitter thread beforehand
  ##
  ## This procedure is intended for interoperability with long-running threads
  ## started with `createThread`
  ## and other threadpools and/or execution engines,
  ## use `spawn` otherwise.
  ##
  ## If the function calls returns a result, submit will wrap it in a Pending[T].
  ## You can use `settle` to block the current thread and extract the asynchronous result from the Pending[T].
  ## You can use `isReady` to check if result is available and if subsequent
  ## `settle` calls would block or return immediately.
  ##
  ## Ensure that before settling on the Pending[T] of a delayed submit, its pledge can be fulfilled or you will deadlock.
  result = submitImpl(pledges, fnCall)

# Sanity checks
# --------------------------------------------------------

when isMainModule:
  import
    ./runtime, ./state_machines/[sync, sync_root],
    ./parallel_tasks,
    std/[os, times, monotimes]

  proc eventLoop(shutdown: ptr Atomic[bool]) {.thread.} =
    init(Weave)
    Weave.runUntil(shutdown)

  var shutdownWeave, serviceDone: Atomic[bool]
  shutdownWeave.store(false, moRelaxed)
  serviceDone.store(false, moRelaxed)

  var executorThread: Thread[ptr Atomic[bool]]
  executorThread.createThread(eventLoop, shutdownWeave.addr)

  block: # Have an independant display service submit jobs to Weave
    serviceDone.store(false, moRelaxed)

    proc display_int(x: int): bool =
      stdout.write(x)
      stdout.write(" - SUCCESS\n")

      return true

    proc displayService(serviceDone: ptr Atomic[bool]) =
      setupJobProvider(Weave)
      waitUntilReady(Weave)

      echo "Sanity check 1: Printing 123456 654321 in parallel"
      discard submit display_int(123456)
      let ok = submit display_int(654321)

      discard waitFor(ok)
      serviceDone[].store(true, moRelaxed)

    var t: Thread[ptr Atomic[bool]]
    t.createThread(displayService, serviceDone.addr)
    joinThread(t)

  block: # Job that spawns tasks
    serviceDone.store(false, moRelaxed)

    proc async_fib(n: int): int =

      if n < 2:
        return n

      let x = spawn async_fib(n-1)
      let y = async_fib(n-2)

      result = sync(x) + y

    proc fibonacciService(serviceDone: ptr Atomic[bool]) =
      setupJobProvider(Weave)
      waitUntilReady(Weave)

      echo "Sanity check 2: fib(20)"
      let f = submit async_fib(20)

      echo waitFor(f)
      serviceDone[].store(true, moRelaxed)

    var t: Thread[ptr Atomic[bool]]
    t.createThread(fibonacciService, serviceDone.addr)
    joinThread(t)


  # Wait until all tests are done
  var backoff = 1
  while not serviceDone.load(moRelaxed):
    sleep(backoff)
    backoff *= 2
    if backoff > 16:
      backoff = 16

  shutdownWeave.store(true)
