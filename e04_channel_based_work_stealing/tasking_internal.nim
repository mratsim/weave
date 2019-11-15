import
  # Standard library
  atomics, cpuinfo,
  os, strutils,
  # Internal
  ./platform, ./task,
  ./profile, ./affinity,
  ./primitives/[c, threads]

  # TODO: document compilation flags

when defined(USE_COZ):
  import ./coz

# Tasking internal
# ----------------------------------------------------------------------------------

# Shared state
# ----------------------------------------------------------------------------------

when defined(DISABLE_MANAGER):
  var td_count*: ptr Atomic[int32]

const MaxWorkers* = 256

var num_workers*: int32

# Private state
# ----------------------------------------------------------------------------------

type WorkerState = enum
  Working
  Idle

var ID* {.threadvar.}: int32
var num_tasks_exec* {.threadvar.}: int
when StealStrategy == StealKind.adaptative:
  var num_tasks_exec_recently* {.threadvar.}: int32
var worker_state {.threadvar.}: WorkerState # unused unless manger is disabled
var tasking_finished* {.threadvar.}: bool

const MasterID* = 0'i32
template Master*(body: untyped): untyped {.dirty.} =
  bind MasterID
  if ID == MasterId:
    body
template Worker*(body: untyped): untyped {.dirty.} =
  if ID != MasterId:
    body

# Task status
# ----------------------------------------------------------------------------------

var current_task {.threadvar.}: Task

proc set_current_task*(task: Task) {.inline.} =
  current_task = task

proc get_current_task*(): Task {.inline.} =
  current_task

proc is_root_task*(task: Task): bool {.inline.} =
  task.parent.isNil

# Worker status
# ----------------------------------------------------------------------------------

proc get_worker_state(): WorkerState =
  return worker_state

when defined(DISABLE_MANAGER):
  proc set_worker_state(state: WorkerState) {.inline.} =
    assert worker_state != state

    worker_state = state
    case worker_state
    of Working: atomicDec(td_count[])
    of Idle: atomicInc(td_count[])
else:
  proc set_worker_state(state: WorkerState) {.inline.} =
    worker_state = state

proc is_idle(): bool {.inline.} =
  get_worker_state() == Idle

proc is_working(): bool {.inline.} =
  get_worker_state() == Working

proc set_idle() {.inline.} =
  set_worker_state(Idle)

proc set_working() {.inline.} =
  set_worker_state(Working)

# Running a task
# ----------------------------------------------------------------------------------

# # Debug
# template log(args: varargs[untyped]): untyped =
#   printf(args)
#   flushFile(stdout)

proc run_task*(task: Task) {.inline.} =
  assert not task.fn.isNil, "Thread: " & $ID & " received a null task function."

  when false:
    if task.is_loop:
      fprintf(stderr, "%2d: Running [%2ld,%2ld)\n", ID, task.start, task.stop)

  task.fn(task.data.addr)
  if task.is_loop:
    # We have executed |stop-start| iterations
    let n = int abs(task.stop - task.start)
    num_tasks_exec += n
    when StealStrategy == StealKind.adaptative:
      num_tasks_exec_recently += n.int32
  else:
    inc num_tasks_exec
    when StealStrategy == StealKind.adaptative:
      inc num_tasks_exec_recently

# ----------------------------------------------------------------------------------

var IDs*: ptr UncheckedArray[int32]
var worker_threads*: ptr UncheckedArray[Pthread]
var global_barrier*{.noinit.}: PthreadBarrier

# ----------------------------------------------------------------------------------

proc tasking_internal_barrier*(): Errno =
  pthread_barrier_wait(global_barrier)

# Statistics
# ----------------------------------------------------------------------------------

profile_extern_decl(run_task)
profile_extern_decl(enq_deq_task)
profile_extern_decl(send_recv_task)
profile_extern_decl(send_recv_req)
profile_extern_decl(idle)

var
  requests_sent*{.threadvar.}, requests_handled*{.threadvar.}: int32
  requests_declined*{.threadvar.}, tasks_sent*{.threadvar.}: int32
  tasks_split*{.threadvar.}: int32

when defined(StealBackoff):
  # TODO: add to compilation flags list
  var requests_resent*{.threadvar.}: int32
when StealStrategy == StealKind.adaptative:
  var requests_steal_one*{.threadvar.}: int32
  var requests_steal_half*{.threadvar.}: int32
when defined(LazyFutures):
  var futures_converted*{.threadvar.}: int32


proc tasking_internal_statistics*() =
  when true:
    Master:
      printf("\n")
      printf("+========================================+\n")
      printf("|  Per-worker statistics                 |\n")
      printf("+========================================+\n")
      printf("  / use -d:profile for high-res timers /  \n")

    discard tasking_internal_barrier()

    printf("Worker %d: %u steal requests sent\n", ID, requests_sent)
    printf("Worker %d: %u steal requests handled\n", ID, requests_handled)
    printf("Worker %d: %u steal requests declined\n", ID, requests_declined)
    printf("Worker %d: %u tasks executed\n", ID, num_tasks_exec)
    printf("Worker %d: %u tasks sent\n", ID, tasks_sent)
    printf("Worker %d: %u tasks split\n", ID, tasks_split)
    when defined(StealBackoff):
      printf("Worker %d: %u steal requests resent\n", ID, requests_resent)
    when StealStrategy == StealKind.adaptative:
      assert(requests_steal_one + requests_steal_half == requests_sent)
      if requests_sent != 0:
        printf("Worker %d: %.2f %% steal-one\n", ID,
          requests_steal_one.float64 / requests_sent.float64 * 100)
        printf("Worker %d: %.2f %% steal-half\n", ID,
          requests_steal_half.float64 / requests_sent.float64 * 100)
      else:
        printf("Worker %d: %.2f %% steal-one\n", ID, 0)
        printf("Worker %d: %.2f %% steal-half\n", ID, 0)
    when defined(LazyFutures):
      printf("Worker %d: %u futures converted\n", ID, futures_converted)

    profile_results()
    flushFile(stdout)

# pthread_create initializer
# ----------------------------------------------------------------------------------

# see `tasking_runtime.nim
# for worker_entry_fn

# Init tasking system
# ----------------------------------------------------------------------------------

# see `tasking_runtime.nim
# for tasking_internal_init

# Teardown tasking system
# ----------------------------------------------------------------------------------

proc tasking_internal_exit*() =
  # Join worker threads
  for i in 1 ..< num_workers:
    discard pthread_join(worker_threads[i], nil)

  discard pthread_barrier_destroy(global_barrier)
  free(worker_threads)
  free(IDs)
  when defined(DISABLE_MANAGER):
    free(td_count)

  # Deallocate root task
  assert current_task.is_root_task()
  free(current_task)

when defined(DISABLED_MANAGER):
  proc tasking_all_idle(): bool =
    return load(td_count, moRelaxed) == num_workers

proc tasking_done*(): bool =
  return tasking_finished
