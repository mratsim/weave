# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./instrumentation/[contracts, profilers, loggers],
  ./primitives/barriers,
  ./datatypes/[sync_types, prell_deques, context_thread_local, flowvars],
  ./channels/[channels_mpsc_bounded_lock, channels_spsc_single_ptr, channels_spsc_single_object],
  ./memory/[persistacks, intrusive_stacks],
  ./contexts, ./config,
  ./victims, ./loop_splitting,
  ./thieves, ./workers


# Public routines
# ----------------------------------------------------------------------------------


# Local context
# ----------------------------------------------------------------------------------

proc init*(ctx: var TLContext) =
  ## Initialize the thread-local context of a worker (including the lead worker)

  myWorker().deque = newPrellDeque(Task)
  myThieves().initialize(WV_MaxConcurrentStealPerWorker * workforce())
  myTodoBoxes().initialize()
  localCtx.stealCache.initialize()
  myWorker().initialize(maxID = workforce() - 1)

  ascertain: myTodoBoxes().len == WV_MaxConcurrentStealPerWorker

  # Workers see their RNG with their myID()
  myThefts().rng = uint32 myID()

  # Thread-Local Profiling
  profile_init(run_task)
  profile_init(enq_deq_task)
  profile_init(send_recv_task)
  profile_init(send_recv_req)
  profile_init(idle)

# Scheduler
# ----------------------------------------------------------------------------------

proc nextTask*(childTask: bool): Task {.inline.} =

  profile(enq_deq_task):
    if childTask:
      result = myWorker().deque.popFirstIfChild(myTask())
    else:
      result = myWorker().deque.popFirst()

  # TODO: steal early

  shareWork()

  # Check if someone requested to steal from us
  var req: StealRequest
  while recv(req):
    # If we just popped a loop task, we may split it here
    # It makes dispatching tasks simpler
    if myWorker().deque.isEmpty() and result.isSplittable():
      if req.thiefID != myID():
        splitAndSend(result, req)
      else:
        forget(req)
    else:
      dispatchTasks(req)

proc declineAll*() =
  var req: StealRequest

  profile_stop(idle)

  if recv(req):
    if req.thiefID == myID() and req.state == Working:
      req.state = Stealing
    decline(req)

  profile_start(idle)

proc schedulingLoop() =
  ## Each worker thread execute this loop over and over

  while not localCtx.signaledTerminate:
    # Global state is intentionally minimized,
    # It only contains the communication channels and read-only environment variables
    # There is still the global barrier to ensure the runtime starts or stops only
    # when all threads are ready.

    # 1. Private task deque
    debug: log("Worker %d: schedloop 1 - task from local deque\n", myID())
    while (let task = nextTask(childTask = false); not task.isNil):
      # Prio is: children, then thieves then us
      ascertain: not task.fn.isNil
      profile(run_task):
        run(task)
      profile(enq_deq_task):
        # The memory is reused but not zero-ed
        localCtx.taskCache.add(task)

    # 2. Run out-of-task, become a thief
    debug: log("Worker %d: schedloop 2 - becoming a thief\n", myID())
    trySteal(isOutOfTasks = true)
    ascertain: myThefts().outstanding > 0

    var task: Task
    profile(idle):
      while not recv(task, isOutOfTasks = true):
        ascertain: myWorker().deque.isEmpty()
        ascertain: myThefts().outstanding > 0
        declineAll()

    # 3. We stole some task(s)
    ascertain: not task.fn.isNil
    debug: log("Worker %d: schedloop 3 - stoled tasks\n", myID())

    let loot = task.batch
    if loot > 1:
      # Add everything
      myWorker().deque.addListFirst(task, loot)
      # And then only use the last
      task = myWorker().deque.popFirst()

    StealAdaptative:
      myThefts().recentThefts += 1

    # 4. Share loot with children
    debug: log("Worker %d: schedloop 4 - sharing work\n", myID())
    shareWork()

    # 5. Work on what is left
    debug: log("Worker %d: schedloop 5 - working on leftover\n", myID())
    profile(run_task):
      run(task)
    profile(enq_deq_task):
      # The memory is reused but not zero-ed
      localCtx.taskCache.add(task)

proc threadLocalCleanup*() =
  myWorker().deque.delete()
  `=destroy`(localCtx.taskCache)
  myThieves().delete()

  for i in 0 ..< WV_MaxConcurrentStealPerWorker:
    # No tasks left
    ascertain: myTodoBoxes().access(i).isEmpty()
    # No need to destroy it's on the stack

  # A BoundedQueue (work-sharing requests) is on the stack
  # It contains steal requests for non-leaf workers
  # but those are on the stack as well and auto-destroyed

  # The task cache is full of tasks
  `=destroy`(localCtx.taskCache)

proc worker_entry_fn*(id: WorkerID) =
  ## On the start of the threadpool workers will execute this
  ## until they receive a termination signal
  # We assume that thread_local variables start all at their binary zero value
  preCondition: localCtx == default(TLContext)

  myID() = id # If this crashes, you need --tlsemulation:off
  localCtx.init()
  discard pthread_barrier_wait(globalCtx.barrier)

  {.gcsafe.}: # Not GC-safe when multi-threaded due to globals
    schedulingLoop()

  # 1 matching barrier in init(Runtime) for lead thread
  discard pthread_barrier_wait(globalCtx.barrier)

  # 1 matching barrier in init(Runtime) for lead thread
  workerMetrics()

  threadLocalCleanup()

EagerFV:
  template isFutReady(): untyped =
    fv.chan.tryRecv(parentResult)
LazyFV:
  template isFutReady(): untyped =
    if fv.lazyFV.hasChannel:
      ascertain: not fv.lazyFV.lazy_chan.chan.isNil
      fv.lazyFV.lazyChan.chan.tryRecv(parentResult)
    else:
      fv.lazyFV.isReady

proc forceFuture*[T](fv: Flowvar[T], parentResult: var T) =
  ## Eagerly complete an awaited FlowVar
  let thisTask = myTask() # Only for ascertain

  block CompleteFuture:
    # Almost duplicate of schedulingLoop and sync() barrier
    if isFutReady():
      break CompleteFuture

    ## 1. Process all the children of the current tasks (and only them)
    debug: log("Worker %d: forcefut 1 - task from local deque\n", myID())
    while (let task = nextTask(childTask = true); not task.isNil):
      profile(run_task):
        run(task)
      profile(enq_deq_task):
        localCtx.taskCache.add(task)
      if isFutReady():
        break CompleteFuture

    # ascertain: myTask() == thisTask # need to be able to print tasks TODO

    # 2. Run out-of-task, become a thief and help other threads
    #    to reach children faster
    debug: log("Worker %d: forcefut 2 - becoming a thief\n", myID())
    while not isFutReady():
      trySteal(isOutOfTasks = false)
      var task: Task
      profile(idle):
        while not recv(task, isOutOfTasks = false):
          # We might inadvertently remove our own steal request in
          # dispatchTasks so resteal
          profile_stop(idle)
          trySteal(isOutOfTasks = false)
          # If someone wants our non-child tasks, let's oblige
          var req: StealRequest
          while recv(req):
            dispatchTasks(req)
          profile_start(idle)
          if isFutReady():
            profile_stop(idle)
            break CompleteFuture

      # 3. We stole some task(s)
      ascertain: not task.fn.isNil
      debug: log("Worker %d: forcefut 3 - stoled tasks\n", myID())

      let loot = task.batch
      if loot > 1:
        profile(enq_deq_task):
          # Add everything
          myWorker().deque.addListFirst(task, loot)
          # And then only use the last
          task = myWorker().deque.popFirst()

      StealAdaptative:
        myThefts().recentThefts += 1

      # Share loot with children workers
      debug: log("Worker %d: forcefut 4 - sharing work\n", myID())
      shareWork()

      # Run the rest
      profile(run_task):
        run(task)
      profile(enq_deq_task):
        # The memory is reused but not zero-ed
        localCtx.taskCache.add(task)

  LazyFV:
    # Cleanup the lazy flowvar if allocated or copy directly into result
    if not fv.lazyFV.hasChannel:
      ascertain: fv.lazyFV.isReady
      copyMem(parentResult.addr, fv.lazyFV.lazyChan.buf.addr, sizeof(parentResult))
    else:
      ascertain: not fv.lazyFV.lazyChan.chan.isNil
      fv.lazyFV.lazyChan.chan.delete()

proc schedule*(task: sink Task) =
  ## Add a new task to be scheduled in parallel
  preCondition: not task.fn.isNil
  myWorker().deque.addFirst task

  profile_stop(enq_deq_task)

  # Lead thread
  if localCtx.runtimeIsQuiescent:
    ascertain: myID() == LeaderID
    debugTermination:
      log(">>> Worker %d resumes execution after barrier <<<\n", myID())
    localCtx.runtimeIsQuiescent = false

  shareWork()

  # Check if someone requested a steal
  var req: StealRequest
  while recv(req):
    dispatchTasks(req)

  profile_start(enq_deq_task)

  ## TODO steal early
