# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[context_global, context_thread_local, sync_types],
  ./channels/[channels_spsc_single_ptr, channels_mpsc_bounded_lock, channels_mpsc_unbounded],
  ./memory/[persistacks, intrusive_stacks],
  ./config,
  system/ansi_c,
  ./primitives/barriers,
  ./instrumentation/[contracts, profilers, loggers]

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

# Task caching
# ----------------------------------------------------------------------------------

proc newTaskFromCache*(): Task {.inline.} =
  if localCtx.taskCache.isEmpty():
    allocate(result)
  else:
    result = localCtx.taskCache.pop()

# Aliases
# ----------------------------------------------------------------------------------

template myTodoBoxes*: Persistack[WV_MaxConcurrentStealPerWorker, ChannelSpscSinglePtr[Task]] =
  globalCtx.com.tasks[localCtx.worker.ID]

# TODO: used to debug a recurrent deadlock on trySend with 5 workers
import ./channels/channels_legacy

func trySend*[T](c: ChannelLegacy[T], src: sink T): bool {.inline.} =
  channel_send(c, src, int32 sizeof(src))

func tryRecv*[T](c: ChannelLegacy[T], dst: var T): bool {.inline.} =
  channel_receive(c, dst.addr, int32 sizeof(dst))

func peek*[T](c: ChannelLegacy[T]): int32 =
  channel_peek(c)

proc initialize*[T](c: var ChannelLegacy[T], size: int32) =
  c = channel_alloc(int32 sizeof(T), size, Mpsc)

proc delete*[T](c: var ChannelLegacy[T]) =
  channel_free(c)

template myThieves*: ChannelMpscUnbounded[StealRequest] =
  globalCtx.com.thefts[localCtx.worker.ID]

template workforce*: int32 =
  globalCtx.numWorkers

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

template isRootTask*(task: Task): bool =
  task.parent.isNil

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

    c_printf("Worker %d: %u steal requests sent\n", myID(), localCtx.counters.stealSent)
    c_printf("Worker %d: %u steal requests handled\n", myID(), localCtx.counters.stealHandled)
    c_printf("Worker %d: %u steal requests declined\n", myID(), localCtx.counters.stealDeclined)
    c_printf("Worker %d: %u tasks executed\n", myID(), localCtx.counters.tasksExec)
    c_printf("Worker %d: %u tasks sent\n", myID(), localCtx.counters.tasksSent)
    c_printf("Worker %d: %u tasks split\n", myID(), localCtx.counters.tasksSplit)
    when defined(StealBackoff):
      c_printf("Worker %d: %u steal requests resent\n", myID(), localCtx.counters.stealResent)
    StealAdaptative:
      ascertain: localCtx.counters.stealOne + localCtx.counters.stealHalf == localCtx.counters.stealSent
      if localCtx.counters.stealSent != 0:
        c_printf("Worker %d: %.2f %% steal-one\n", myID(),
          localCtx.counters.stealOne.float64 / localCtx.counters.stealSent.float64 * 100)
        c_printf("Worker %d: %.2f %% steal-half\n", myID(),
          localCtx.counters.stealHalf.float64 / localCtx.counters.stealSent.float64 * 100)
      else:
        c_printf("Worker %d: %.2f %% steal-one\n", myID(), 0)
        c_printf("Worker %d: %.2f %% steal-half\n", myID(), 0)
    LazyFV:
      c_printf("Worker %d: %u futures converted\n", myID(), localCtx.counters.futuresConverted)
    c_printf("Worker %d: random victim fast path (slow path): %3.0f %% (%3.0f %%)\n",
      myID(), localCtx.counters.randomVictimEarlyExits.float64 * 100 / localCtx.counters.randomVictimCalls.float64,
      100 - localCtx.counters.randomVictimEarlyExits.float64 * 100 / localCtx.counters.randomVictimCalls.float64
    )

    profile_results(myID())
    flushFile(stdout)
