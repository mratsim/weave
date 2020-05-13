# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[context_global, context_thread_local, sync_types, prell_deques, binary_worker_trees],
  ./cross_thread_com/[channels_spsc_single_ptr, channels_mpsc_unbounded_batch, scoped_barriers, pledges],
  ./memory/[persistacks, lookaside_lists, memory_pools, allocs],
  ./config,
  ./instrumentation/[profilers, loggers, contracts]

when defined(WV_metrics):
  import system/ansi_c, ./primitives/barriers

Backoff:
  import ./cross_thread_com/event_notifiers

# Contexts
# ----------------------------------------------------------------------------------

type Weave* = object

var globalCtx*: GlobalContext
var workerContext* {.threadvar.}: WorkerContext
  ## Worker context
  # TODO: tlsEmulation off by default on OSX and on by default on iOS?

var jobProviderContext* {.threadvar.}: JobProviderContext

const RootID*: WorkerID = 0

# Profilers
# ----------------------------------------------------------------------------------

profile_extern_decl(run_task)
profile_extern_decl(send_recv_req)
profile_extern_decl(send_recv_task)
profile_extern_decl(enq_deq_task)
profile_extern_decl(idle)

# TODO, many visibility issues with profilers and timers
import instrumentation/timers
export timers

# Aliases
# ----------------------------------------------------------------------------------

template isRootTask*(task: Task): bool =
  task.parent.isNil

template myTodoBoxes*: Persistack[WV_MaxConcurrentStealPerWorker, ChannelSpscSinglePtr[Task]] =
  globalCtx.com.tasksStolen[workerContext.worker.ID]

template myThieves*: ChannelMpscUnboundedBatch[StealRequest] =
  globalCtx.com.thefts[workerContext.worker.ID]

template getThievesOf*(worker: WorkerID): ChannelMpscUnboundedBatch[StealRequest] =
  globalCtx.com.thefts[worker]

template myMemPool*: TLPoolAllocator =
  globalCtx.mempools[workerContext.worker.ID]

template workforce*: int32 =
  globalCtx.numWorkers

template maxID*: int32 =
  globalCtx.numWorkers - 1

template myID*: WorkerID =
  workerContext.worker.ID

template myWorker*: Worker =
  workerContext.worker

template myTask*: Task =
  workerContext.worker.currentTask

template myThefts*: Thefts =
  workerContext.thefts

template myMetrics*: untyped =
  metrics:
    workerContext.counters

template mySyncScope*: ptr ScopedBarrier =
  workerContext.worker.currentScope

Backoff:
  template myParking*: EventNotifier =
    globalCtx.com.parking[workerContext.worker.ID]

  template wakeup*(target: WorkerID) =
    mixin notify
    debugTermination:
      log("Worker %2d: waking up child %2d\n", workerContext.worker.ID, target)
    globalCtx.com.parking[target].notify()

  export event_notifiers.park, event_notifiers.prepareToPark, event_notifiers.initialize, event_notifiers.EventNotifier

# Task caching
# ----------------------------------------------------------------------------------

proc newTaskFromCache*(): Task =
  result = workerContext.taskCache.pop()
  if result.isNil:
    result = myMemPool().borrow(deref(Task))
  # Zeroing is expensive, it's 96 bytes

  # result.fn = nil # Always overwritten
  # result.parent = nil # Always overwritten
  # result.scopedBarrier = nil # Always overwritten
  result.prev = nil
  result.next = nil
  result.start = 0
  result.cur = 0
  result.stop = 0
  result.stride = 0
  result.futures = nil
  result.isLoop = false
  result.hasFuture = false

proc delete*(task: Task) {.inline.} =
  preCondition: not task.isNil()
  recycle(task)

iterator items(t: Task): Task =
  var cur = t
  while not cur.isNil:
    let next = cur.next
    yield cur
    cur = next

proc flushAndDispose*(dq: var PrellDeque) =
  let leftovers = flush(dq)
  for task in items(leftovers):
    recycle(task)

# Pledges - Dataflow parallelism
# ----------------------------------------------------------------------------------
proc newPledge*(): Pledge =
  ## Creates a pledge
  ## Tasks associated with a pledge are only scheduled when the pledge is fulfilled.
  ## A pledge can only be fulfilled once.
  ## Pledges enable modeling precise producer-consumer data dependencies.
  result.initialize(myMemPool())

proc newPledge*(start, stop, stride: SomeInteger): Pledge =
  ## Creates a loop iteration pledge.
  ## With a loop iteration pledge, tasks can be associated with a precise loop index.
  ##
  ## Tasks associated with a pledge are only scheduled when the pledge is fulfilled.
  ## A pledge can only be fulfilled once.
  ## Pledges enable modeling precise producer-consumer data dependencies.
  result.initialize(myMemPool(), start.int32, stop.int32, stride.int32)

proc fulfill*(pledge: Pledge) =
  ## Fulfills a pledge
  ## All ready tasks that depended on that pledge will be scheduled immediately.
  ## A ready task is a task that has all its pledged dependencies fulfilled.
  fulfillImpl(pledge, myWorker().deque, addFirst)

proc fulfill*(pledge: Pledge, index: SomeInteger) =
  ## Fulfills an iteration pledge
  ## All ready tasks that depended on that pledge will be scheduled immediately.
  ## A ready task is a task that has all its pledged dependencies fulfilled.
  fulfillIterImpl(pledge, int32(index), myWorker().deque, addFirst)

# Dynamic Scopes
# ----------------------------------------------------------------------------------

template Root*(body: untyped) =
  if workerContext.worker.ID == RootID:
    body

template Worker*(body: untyped) =
  if workerContext.worker.ID != RootID:
    body

# Counters
# ----------------------------------------------------------------------------------

template incCounter*(name: untyped{ident}, amount = 1) =
  bind name
  metrics:
    # Assumes workerContext is in the calling context
    workerContext.counters.name += amount

template decCounter*(name: untyped{ident}) =
  bind name
  metrics:
    # Assumes workerContext is in the calling context
    workerContext.counters.name -= 1

proc workerMetrics*() =
  metrics:
    Root:
      c_printf("\n")
      c_printf("+========================================+\n")
      c_printf("|  Per-worker statistics                 |\n")
      c_printf("+========================================+\n")
      c_printf("  / use -d:WV_profile for high-res timers /  \n")

    discard globalCtx.barrier.wait()

    c_printf("Worker %2d: %u steal requests sent\n", myID(), workerContext.counters.stealSent)
    c_printf("Worker %2d: %u steal requests handled\n", myID(), workerContext.counters.stealHandled)
    c_printf("Worker %2d: %u steal requests declined\n", myID(), workerContext.counters.stealDeclined)
    c_printf("Worker %2d: %u tasks executed\n", myID(), workerContext.counters.tasksExec)
    c_printf("Worker %2d: %u tasks sent\n", myID(), workerContext.counters.tasksSent)
    c_printf("Worker %2d: %u loops split\n", myID(), workerContext.counters.loopsSplit)
    c_printf("Worker %2d: %u loops iterations executed\n", myID(), workerContext.counters.loopsIterExec)
    StealAdaptative:
      ascertain: workerContext.counters.stealOne + workerContext.counters.stealHalf == workerContext.counters.stealSent
      if workerContext.counters.stealSent != 0:
        c_printf("Worker %2d: %.2f %% steal-one\n", myID(),
          workerContext.counters.stealOne.float64 / workerContext.counters.stealSent.float64 * 100)
        c_printf("Worker %2d: %.2f %% steal-half\n", myID(),
          workerContext.counters.stealHalf.float64 / workerContext.counters.stealSent.float64 * 100)
      else:
        c_printf("Worker %2d: %.2f %% steal-one\n", myID(), 0)
        c_printf("Worker %2d: %.2f %% steal-half\n", myID(), 0)
    LazyFV:
      c_printf("Worker %2d: %u futures converted\n", myID(), workerContext.counters.futuresConverted)

    profile_results(myID())
    flushFile(stdout)
