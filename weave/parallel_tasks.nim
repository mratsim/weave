# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# A task is a processing request emitted from a Weave worker thread.
# They are scheduled in LIFO order and maximize throughput of the runtime.
# In particular, it is optimized for fork-join parallelism
# where the oldest tasks spawned the recent ones and cannot complete
# without the recent tasks being complete.

# Async/await spawn/sync for compute bound tasks
# ----------------------------------------------------------

import
  # Standard library
  macros, typetraits,
  # Internal
  ./scheduler, ./contexts,
  ./datatypes/[flowvars, sync_types],
  ./instrumentation/contracts,
  ./cross_thread_com/[scoped_barriers, flow_events]


proc spawnImpl(events: NimNode, funcCall: NimNode): NimNode =
  # We take typed argument so that overloading resolution
  # is already done and arguments are semchecked
  funcCall.expectKind(nnkCall)
  result = newStmtList()
  result.add quote do:
    preCondition: onWeaveThread()

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

  # Schedule immediately or delay on dependencies
  var scheduleBlock: NimNode
  let task = ident"task"
  if events.isNil:
    scheduleBlock = newCall(bindSym"schedule", task)
  elif events.len == 1:
    let eventDesc = events[0]
    if eventDesc.kind in {nnkIdent, nnkSym}:
      scheduleBlock = quote do:
        if not delayedUntil(`task`, `eventDesc`, myMemPool()):
          schedule(`task`)
    else:
      eventDesc.expectKind({nnkPar, nnkTupleConstr})
      let event = eventDesc[0]
      let eventIndex = eventDesc[1]
      scheduleBlock = quote do:
        if not delayedUntil(`task`, `event`, int32(`eventIndex`), myMemPool()):
          schedule(`task`)
  else:
    let delayedMulti = getAst(delayedUntilMulti(
      task, newCall(bindSym"myMemPool"), events)
    )
    scheduleBlock = quote do:
      if not `delayedMulti`:
        schedule(`task`)

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
        preCondition: not isRootTask(myTask())

        when bool(`withArgs`):
          let `data` = cast[ptr `argsTy`](param) # TODO - restrict
        `fnCall`
    # Create the task
    result.add quote do:
      when defined(WV_profile):
        # TODO profiling templates visibility issue
        timer_start(timer_enq_deq_task)
      block enq_deq_task:
        let `task` = newTaskFromCache()
        `task`.parent = myTask()
        `task`.fn = `async_fn`
        registerDescendant(mySyncScope())
        `task`.scopedBarrier = mySyncScope()
        when bool(`withArgs`):
          cast[ptr `argsTy`](`task`.data.addr)[] = `args`
        `scheduleBlock`
      when defined(WV_profile):
        timer_stop(timer_enq_deq_task)

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
        preCondition: not isRootTask(myTask())

        let `data` = cast[ptr `futArgsTy`](param) # TODO - restrict
        let res = `fnCall`
        when typeof(`data`[]) is Flowvar:
          readyWith(`data`[], res)
        else:
          readyWith(`data`[0], res)

    # Create the task
    let freshIdent = ident($retType)
    result.add quote do:
      when defined(WV_profile):
        # TODO profiling templates visibility issue
        timer_start(timer_enq_deq_task)
      block enq_deq_task:
        let `task` = newTaskFromCache()
        `task`.parent = myTask()
        `task`.fn = `async_fn`
        registerDescendant(mySyncScope())
        `task`.scopedBarrier = mySyncScope()
        `task`.has_future = true
        `task`.futureSize = uint8(sizeof(`retType`))
        let `fut` = newFlowvar(myMemPool(), `freshIdent`)
        cast[ptr `futArgsTy`](`task`.data.addr)[] = `futArgs`
        `scheduleBlock`
        when defined(WV_profile):
          timer_stop(timer_enq_deq_task)
        # Return the future
        `fut`

  # Wrap in a block for namespacing
  result = nnkBlockStmt.newTree(newEmptyNode(), result)
  # echo result.toStrLit

macro spawn*(fnCall: typed): untyped =
  ## Spawns the input function call asynchronously, potentially on another thread of execution.
  ##
  ## To offload computation from a thread started with `createdThread`
  ## (i.e. foreign to the Weave runtime)
  ## use `setupSubmitterThread` + `submit` instead.
  ##
  ## If the function calls returns a result, spawn will wrap it in a Flowvar.
  ## You can use `sync` to block the current thread and extract the asynchronous result from the flowvar.
  ## You can use `isReady` to check if result is available and if subsequent
  ## `spawn` returns immediately.
  ##
  ## Tasks are processed approximately in Last-In-First-Out (LIFO) order
  result = spawnImpl(nil, fnCall)

macro spawnOnEvents*(events: varargs[typed], fnCall: typed): untyped =
  ## Spawns the input function call asynchronously, potentially on another thread of execution.
  ## The function call will only be scheduled when the events are triggered.
  ##
  ## If the function calls returns a result, spawn will wrap it in a Flowvar.
  ## You can use sync to block the current thread and extract the asynchronous result from the flowvar.
  ##
  ## spawnOnEvents returns immediately.
  ##
  ## Ensure that before syncing on the flowvar of a triggered spawn,
  ## its events can be triggered or you will deadlock.
  result = spawnImpl(events, fnCall)

macro spawnOnEvent*(event: FlowEvent, fnCall: typed): untyped =
  ## Spawns the input function call asynchronously, potentially on another thread of execution.
  ## The function call will only be scheduled when the event is triggered.
  ##
  ## If the function calls returns a result, spawn will wrap it in a Flowvar.
  ## You can use sync to block the current thread and extract the asynchronous result from the flowvar.
  ##
  ## spawnOnEvent returns immediately.
  ##
  ## Ensure that before syncing on the flowvar of a triggered spawn,
  ## its event can be triggered or you will deadlock.
  result = spawnImpl(nnkArgList.newTree(event), fnCall)

# Sanity checks
# --------------------------------------------------------

when isMainModule:
  import
    ./runtime, ./state_machines/[sync, sync_root], os,
    std/[times, monotimes]

  block: # Async without result

    proc display_int(x: int) =
      stdout.write(x)
      stdout.write(" - SUCCESS\n")

    proc main() =
      echo "Sanity check 1: Printing 123456 654321 in parallel"

      init(Weave)
      spawn display_int(123456)
      spawn display_int(654321)
      exit(Weave)

    main()

  block: # Async/Await

    proc async_fib(n: int): int =

      if n < 2:
        return n

      let x = spawn async_fib(n-1)
      let y = async_fib(n-2)

      result = sync(x) + y

    proc main2() =
      echo "Sanity check 2: fib(20)"

      init(Weave)
      let f = async_fib(20)
      exit(Weave)

      echo f

    main2()

  block: # isReady
    template dummy_cpt(): untyped =
      # Dummy computation
      # Calculate fib(30) iteratively
      var
        fib = 0
        f2 = 0
        f1 = 1
      for i in 2 .. 30:
        fib = f1 + f2
        f2 = f1
        f1 = fib

    proc sleepingLion(stop_ms: int64): int64 =
      echo "Entering the Lion's Den"
      let start = getMonoTime()

      while true:
        let elapsed = inMilliseconds(getMonoTime() - start)
        if elapsed >= stop_ms:
          echo "Exiting the Lion's Den"
          return elapsed

        dummy_cpt()

    proc main2() =
      echo "Sanity check 3: isReady"
      const target = 123

      init(Weave)
      echo "Spawning sleeping thread for ", target, " ms"
      let start = getMonoTime()
      let f = spawn sleepingLion(123)
      var spin_count: int64
      while not f.isReady():
        loadBalance(Weave) # We need to send the task away, on OSX CI it seems like threads are not initialized fast enough
        spin_count += 1
      let stopReady = getMonoTime()
      let res = sync(f)
      let stopSync = getMonoTime()
      exit(Weave)

      let readyTime = inMilliseconds(stopReady-start)
      let syncTime = inMilliseconds(stopSync-stopReady)

      echo "Retrieved: ", res, " (isReady: ", readyTime, " ms, sync: ", syncTime, " ms, spin_count: ", spin_count, ")"
      doAssert syncTime <= 1, "sync should be non-blocking"
      # doAssert readyTime in {target-1 .. target+1}, "asking to sleep for " & $target & " ms but slept for " & $readyTime

    main2()

  block: # Delayed computation

    proc echoA(pA: FlowEvent) =
      echo "Display A, sleep 1s, create parallel streams 1 and 2"
      sleep(1000)
      pA.trigger()

    proc echoB1(pB1: FlowEvent) =
      echo "Display B1, sleep 1s"
      sleep(1000)
      pB1.trigger()

    proc echoB2() =
      echo "Display B2, exit stream"

    proc echoC1(): bool =
      echo "Display C1, exit stream"
      return true

    proc main() =
      echo "Sanity check 3: Dataflow parallelism"
      init(Weave)
      let pA = newFlowEvent()
      let pB1 = newFlowEvent()
      let done = spawnOnEvent(pB1, echoC1())
      spawnOnEvent pA, echoB2()
      spawnOnEvent pA, echoB1(pB1)
      spawn echoA(pA)
      discard sync(done)
      exit(Weave)

    main()

  block: # Delayed computation with multiple dependencies

    proc echoA(pA: FlowEvent) =
      echo "Display A, sleep 1s, create parallel streams 1 and 2"
      sleep(1000)
      pA.trigger()

    proc echoB1(pB1: FlowEvent) =
      echo "Display B1, sleep 1s"
      sleep(1000)
      pB1.trigger()

    proc echoB2(pB2: FlowEvent) =
      echo "Display B2, no sleep"
      pB2.trigger()

    proc echoC12() =
      echo "Display C12, exit stream"

    proc main() =
      echo "Sanity check 4: Dataflow parallelism with multiple dependencies"
      init(Weave)
      let pA = newFlowEvent()
      let pB1 = newFlowEvent()
      let pB2 = newFlowEvent()
      spawnOnEvents pB1, pB2, echoC12()
      spawnOnEvent pA, echoB2(pB2)
      spawnOnEvent pA, echoB1(pB1)
      spawn echoA(pA)
      exit(Weave)
      echo "Weave runtime exited"

    main()
