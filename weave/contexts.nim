# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[context_global, context_thread_local, sync_types, prell_deques, binary_worker_trees],
  ./channels/[channels_spsc_single_ptr, channels_mpsc_unbounded_batch, event_notifiers],
  ./memory/[persistacks, lookaside_lists, memory_pools, allocs],
  ./config,
  system/ansi_c,
  ./instrumentation/[profilers, loggers, contracts],
  ./primitives/barriers

# Contexts
# ----------------------------------------------------------------------------------

var globalCtx*: GlobalContext
var localCtx* {.threadvar.}: TLContext
  # TODO: tlsEmulation off by default on OSX and on by default on iOS?

const LeaderID*: WorkerID = 0

# Profilers
# ----------------------------------------------------------------------------------

profile_extern_decl(run_task)
profile_extern_decl(send_recv_req)
profile_extern_decl(send_recv_task)
profile_extern_decl(enq_deq_task)
profile_extern_decl(idle)

# Aliases
# ----------------------------------------------------------------------------------

template isRootTask*(task: Task): bool =
  task.parent.isNil

template myTodoBoxes*: Persistack[WV_MaxConcurrentStealPerWorker, ChannelSpscSinglePtr[Task]] =
  globalCtx.com.tasks[localCtx.worker.ID]

template myThieves*: ChannelMpscUnboundedBatch[StealRequest] =
  globalCtx.com.thefts[localCtx.worker.ID]

template getThievesOf*(worker: WorkerID): ChannelMpscUnboundedBatch[StealRequest] =
  globalCtx.com.thefts[worker]

template myMemPool*: TLPoolAllocator =
  globalCtx.mempools[localCtx.worker.ID]

template workforce*: int32 =
  globalCtx.numWorkers

template maxID*: int32 =
  globalCtx.numWorkers - 1

template myID*: WorkerID =
  localCtx.worker.ID

template myWorker*: Worker =
  localCtx.worker

template myTask*: Task =
  localCtx.worker.currentTask

template myThefts*: Thefts =
  localCtx.thefts

template myMetrics*: untyped =
  metrics:
    localCtx.counters

template myParking*: EventNotifier =
  globalCtx.com.parking[localCtx.worker.ID]

template wakeup*(target: WorkerID) =
  mixin notify
  debugTermination:
    log("Worker %2d: waking up child %2d\n", localCtx.worker.ID, target)
  globalCtx.com.parking[target].notify()

export event_notifiers.wait

# Task caching
# ----------------------------------------------------------------------------------

proc newTaskFromCache*(): Task =
  result = localCtx.taskCache.pop()
  if result.isNil:
    result = myMemPool().borrow(deref(Task))
  # Zeroing is expensive, it's 96 bytes

  # result.fn = nil # Always overwritten
  # result.parent = nil # Always overwritten
  result.prev = nil
  result.next = nil
  result.futures = nil
  result.start = 0
  result.cur = 0
  result.stop = 0
  result.chunks = 0
  result.splitThreshold = 0
  result.batch = 0
  result.isLoop = false
  result.hasFuture = false

proc delete*(task: Task) {.inline.} =
  preCondition: not task.isNil()
  recycle(myID(), task)

iterator items(t: Task): Task =
  var cur = t
  while not cur.isNil:
    let next = cur.next
    yield cur
    cur = next

proc flushAndDispose*(dq: var PrellDeque) =
  let leftovers = flush(dq)
  for task in items(leftovers):
    recycle(myID(), task)

# Dynamic Scopes
# ----------------------------------------------------------------------------------

template Leader*(body: untyped) =
  if localCtx.worker.ID == LeaderID:
    body

template Worker*(body: untyped) =
  if localCtx.worker.ID != LeaderID:
    body

# Counters
# ----------------------------------------------------------------------------------

template incCounter*(name: untyped{ident}, amount = 1) =
  bind name
  metrics:
    # Assumes localCtx is in the calling context
    localCtx.counters.name += amount

template decCounter*(name: untyped{ident}) =
  bind name
  metrics:
    # Assumes localCtx is in the calling context
    localCtx.counters.name -= 1

proc workerMetrics*() =
  metrics:
    Leader:
      c_printf("\n")
      c_printf("+========================================+\n")
      c_printf("|  Per-worker statistics                 |\n")
      c_printf("+========================================+\n")
      c_printf("  / use -d:WV_profile for high-res timers /  \n")

    discard pthread_barrier_wait(globalCtx.barrier)

    c_printf("Worker %2d: %u steal requests sent\n", myID(), localCtx.counters.stealSent)
    c_printf("Worker %2d: %u steal requests handled\n", myID(), localCtx.counters.stealHandled)
    c_printf("Worker %2d: %u steal requests declined\n", myID(), localCtx.counters.stealDeclined)
    c_printf("Worker %2d: %u tasks executed\n", myID(), localCtx.counters.tasksExec)
    c_printf("Worker %2d: %u tasks sent\n", myID(), localCtx.counters.tasksSent)
    c_printf("Worker %2d: %u tasks split\n", myID(), localCtx.counters.tasksSplit)
    StealAdaptative:
      ascertain: localCtx.counters.stealOne + localCtx.counters.stealHalf == localCtx.counters.stealSent
      if localCtx.counters.stealSent != 0:
        c_printf("Worker %2d: %.2f %% steal-one\n", myID(),
          localCtx.counters.stealOne.float64 / localCtx.counters.stealSent.float64 * 100)
        c_printf("Worker %2d: %.2f %% steal-half\n", myID(),
          localCtx.counters.stealHalf.float64 / localCtx.counters.stealSent.float64 * 100)
      else:
        c_printf("Worker %2d: %.2f %% steal-one\n", myID(), 0)
        c_printf("Worker %2d: %.2f %% steal-half\n", myID(), 0)
    LazyFV:
      c_printf("Worker %2d: %u futures converted\n", myID(), localCtx.counters.futuresConverted)

    profile_results(myID())
    flushFile(stdout)
