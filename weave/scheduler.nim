# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./instrumentation/[contracts, profilers, loggers],
  ./primitives/barriers,
  ./datatypes/[sync_types, prell_deques, context_thread_local, sparsesets, binary_worker_trees, bounded_queues],
  ./cross_thread_com/[channels_spsc_single_ptr, channels_mpsc_unbounded_batch],
  ./memory/[persistacks, lookaside_lists, allocs, memory_pools],
  ./contexts, ./config,
  ./random/rng,
  ./state_machines/[event_loop, dispatch_events]

# Local context
# ----------------------------------------------------------------------------------

{.push gcsafe.}

# Caching description:
#
# Thread-local objects, with a lifetime equal to the thread lifetime
# are allocated directly with no caching.
#
# Short-lived synchronization objects are allocated depending on their characteristics
#
# - Steal requests:
#   are bounded, exchanged between threads but by design
#   a thread knows when its steal request is unused:
#   - either it received a corresponding task
#   - or the steal request was return
#
#   So caching is done via a ``Persistack``, a simple stack
#   that can either recycle an object or be notified that object is unused.
#   I.e. even after lending an object its reference persists in the stack.
#
# - Task channels:
#   Similarly, everytime a steal request is created
#   a channel to receive the task must be with the exact same lifetime.
#   A persistack is used as well.
#
# - Flowvars / Futures:
#   are unbounded, visible to users.
#   In the usual case the thread that allocated them, collect them,
#   if the flowvar is awaited in the proc that spawned it.
#   A flowvar may be stolen by another thread if it is returned (not tested at the moment).
#   Tree and recursive algorithms might spawn a huge number of flowvars initially.
#
#   Caching is done via a ``thread-safe memory pool``.
#   If WV_LazyFlowvar, they are allocated on the stack until we have
#   to extend their lifetime beyond the task stack.
#
# - Tasks:
#   are unbounded and either exchanged between threads in case of imbalance
#   or stay within their threads.
#   Tree and recursive algorithms might create a huge number of tasks initially.
#
#   Caching is done via a ``look-aside list`` that cooperate with the memory pool
#   to adaptatively store/release tasks to it.
#
# Note that the memory pool for flowvars and tasks is able to release memory back to the OS
# The memory pool provides a deterministic heartbeat, every ~N allocations (N depending on the arena size)
# expensive pool maintenance is done and amortized.
# The lookaside list hooks in into this heartbeat for its own adaptative processing

# The mempool is initialized in worker_entry_fn
# as the main thread needs it for the root task
proc setupWorker*() =
  ## Initialize the thread-local context of a worker (including the lead worker)
  preCondition: localThreadKind == Unknown

  template ctx: untyped = workerContext
  metrics:
    zeroMem(ctx.counters.addr, sizeof(ctx.counters))
  zeroMem(ctx.thefts.addr, sizeof(ctx.thefts))
  ctx.runtimeIsQuiescent = false
  ctx.signaledTerminate = false

  ctx.taskCache.initialize(freeFn = memory_pools.recycle)
  myMemPool.hook.setCacheMaintenanceEx(ctx.taskCache)

  localThreadKind = WorkerThread

  # Worker
  # -----------------------------------------------------------
  myWorker().initialize(maxID())
  myWorker().deque.initialize()
  myWorker().workSharingRequests.initialize()
  mySyncScope() = nil

  Backoff:
    myParking().initialize()

  myTodoBoxes().initialize()
  for i in 0 ..< myTodoBoxes().len:
    myTodoBoxes().access(i).initialize()

  ascertain: myTodoBoxes().len == WV_MaxConcurrentStealPerWorker

  # Thieves
  # -----------------------------------------------------------
  myThieves().initialize()
  ctx.stealCache.initialize()
  for i in 0 ..< ctx.stealCache.len:
    ctx.stealCache.access(i).victims.allocate(capacity = workforce())

  myThefts().rng.seed(myID())
  TargetLastVictim:
    myThefts().lastVictim = Not_a_worker
  TargetLastThief:
    myThefts().lastThief = Not_a_worker

  # Debug
  # -----------------------------------------------------------
  debugMem:
    let (tStart, tStop) = myTodoBoxes().reservedMemRange()
    log("Worker %2d: tasks channels range       0x%.08x-0x%.08x\n",
      myID(), tStart, tStop
    )
    log("Worker %2d: steal requests channel is  0x%.08x\n",
      myID(), myThieves().addr)
    let (sStart, sStop) = ctx.stealCache.reservedMemRange()
    log("Worker %2d: steal requests cache range 0x%.08x-0x%.08x\n",
      myID(), sStart, sStop)

  postCondition: myWorker().workSharingRequests.isEmpty()
  postCondition: not ctx.signaledTerminate
  postCondition: not myWorker().isWaiting
  postCondition: localThreadKind == WorkerThread

  # Thread-Local Profiling
  # -----------------------------------------------------------
  profile_init(run_task)
  profile_init(enq_deq_task)
  profile_init(send_recv_task)
  profile_init(send_recv_req)
  profile_init(idle)

# Scheduler
# ----------------------------------------------------------------------------------

proc teardownWorker*() =
  myWorker().deque.flushAndDispose()

  for i in 0 ..< WV_MaxConcurrentStealPerWorker:
    # No tasks left
    ascertain: myTodoBoxes().access(i).isEmpty()
    workerContext.stealCache.access(i).victims.delete()
  myTodoBoxes().delete()
  Backoff:
    `=destroy`(myParking())

  # The task cache is full of tasks
  delete(workerContext.taskCache)
  # This also deletes steal requests already sent to other workers
  delete(workerContext.stealCache)
  discard myMemPool().teardown()

  localThreadKind = Unknown

proc worker_entry_fn*(id: WorkerID) =
  ## On the start of the threadpool workers will execute this
  ## until they receive a termination signal
  # We assume that thread_local variables start all at their binary zero value
  preCondition: workerContext == default(WorkerContext)
  preCondition: localThreadKind == Unknown

  myID() = id # If this crashes, you need --tlsemulation:off
  myMemPool().initialize()
  setupWorker()
  discard globalCtx.barrier.wait()

  eventLoop()

  # 1 matching barrier in init(Runtime) for lead thread
  discard globalCtx.barrier.wait()

  # 1 matching barrier in init(Runtime) for lead thread
  workerMetrics()

  teardownWorker()
  postCondition: localThreadKind == Unknown

proc schedule*(task: sink Task) =
  ## Add a new task to be scheduled in parallel
  preCondition: not task.fn.isNil
  debug: log("Worker %2d: scheduling task.fn 0x%.08x (%d pending)\n", myID(), task.fn, myWorker().deque.pendingTasks)

  myWorker().deque.addFirst task

  profile_stop(enq_deq_task)

  # Root thread
  if workerContext.runtimeIsQuiescent:
    ascertain: myID() == RootID
    debugTermination:
      log(">>> Worker %2d resumes execution after barrier <<<\n", myID())
    workerContext.runtimeIsQuiescent = false

  dispatchToChildrenAndThieves()

  profile_start(enq_deq_task)
