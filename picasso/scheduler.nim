# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./instrumentation/[contracts, profilers],
  ./primitives/barriers,
  ./datatypes/[sync_types, prell_deques, context_thread_local],
  ./channels/[channels_mpsc_bounded_lock, channels_spsc_single],
  ./memory/[persistacks, intrusive_stacks],
  ./contexts, ./config,
  ./victims, ./loop_splitting,
  ./thieves, ./workers


# Public routine
# ----------------------------------------------------------------------------------

proc sync*() =
  ## Sync all threads
  discard globalCtx.barrier.pthread_barrier_wait()

# Local context
# ----------------------------------------------------------------------------------

proc init(ctx: var TLContext) =
  ## Initialize the thread-local context of a worker (including the lead worker)

  myWorker().deque = newPrellDeque(Task)
  myThieves().initialize(PI_MaxConcurrentStealPerWorker * workforce())
  myTodoBoxes().initialize()
  myWorker().initialize(maxID = workforce())

  ascertain: myTodoBoxes().len == PI_MaxConcurrentStealPerWorker

  # Workers see their RNG with their ID
  myThefts().rng = uint32 myID()

  # Thread-Local Profiling
  profile_init(run_task)
  profile_init(enq_deq_task)
  profile_init(send_recv_task)
  profile_init(send_recv_req)
  profile_init(idle)

# Scheduler
# ----------------------------------------------------------------------------------

proc nextTask(childTask: bool): Task =

  profile(enq_deq_task):
    if childTask:
      result = myWorker().deque.popFirst()
    else:
      result = myWorker().deque.popFirstIfChild(myTask())

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

proc declineAll() =
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
    while (let task = nextTask(childTask = false); not task.isNil):
      # Prio is: children, then thieves then us
      ascertain: not task.fn.isNil
      profile(run_task):
        run(task)
      profile(enq_deq_task):
        # The memory is reused but not zero-ed
        localCtx.taskCache.add(task)

    # 2. Run out-of-task, become a thief
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

    let loot = task.batch
    if loot > 1:
      # Add everything
      myWorker().deque.addListFirst(task, loot)

    StealAdaptative:
      myThefts().recentThefts += 1

    # 4. Share loot with children
    shareWork()

    # 5. Work on what is left
    profile(run_task):
      run(task)
    profile(enq_deq_task):
      # The memory is reused but not zero-ed
      localCtx.taskCache.add(task)

proc worker_entry_fn(id: WorkerID) =
  ## On the start of the threadpool workers will execute this
  ## until they receive a termination signal
  # We assume that thread_local variables start all at their binary zero value
  preCondition: localCtx == default(TLContext)

  myID() = id # If this crashes, you need --tlsemulation:off
  localCtx.init()
  sync()

  {.gcsafe.}: # Not GC-safe when multi-threaded due to globals
    schedulingLoop()
  sync()
