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
  var td_count: ptr Atomic[int32]

const MaxWorkers* = 256

var num_workers: int32

# Private state
# ----------------------------------------------------------------------------------

type WorkerState = enum
  Working
  Idle

var ID* {.threadvar.}: int32
var num_tasks_exec {.threadvar.}: int32
when StealStrategy == StealKind.adaptative:
  var num_tasks_exec_recently {.threadvar.}: int32
var worker_state {.threadvar.}: WorkerState # unused unless manger is disabled
var tasking_finished {.threadvar.}: bool

const MasterID = 0'i32
template Master(body: untyped): untyped {.dirty.} =
  if ID == MasterId:
    body
template Worker(body: untyped): untyped {.dirty.} =
  if ID != MasterId:
    body

# Task status
# ----------------------------------------------------------------------------------

var current_task {.threadvar.}: Task

proc set_current_task(task: Task) {.inline.} =
  current_task = task

proc get_current_task(): Task {.inline.} =
  current_task

proc is_root_task(task: Task): bool {.inline.} =
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
    of Working: atomicDec(td_count)
    of Idle: atomicInc(td_count)
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

proc run_task(task: Task) {.inline.} =
  when false:
    if task.is_loop:
      fprintf(stderr, "%2d: Running [%2ld,%2ld)\n", ID, task.start, task.stop)

  let this = get_current_task()
  set_current_task(task)
  task.fn(task.data.addr)
  set_current_task(this)
  if task.is_loop:
    # We have executed |stop-start| iterations
    let n = abs(task.stop - task.start)
    num_tasks_exec += n
    when StealStrategy == StealKind.adaptative:
      num_tasks_exec_recently += n
  else:
    inc num_tasks_exec
    when StealStrategy == StealKind.adaptative:
      inc num_tasks_exec_recently

# ----------------------------------------------------------------------------------

var IDs: ptr UncheckedArray[int32]
var worker_threads: ptr UncheckedArray[Pthread]
var global_barrier{.noinit.}: PthreadBarrier

# ----------------------------------------------------------------------------------

proc tasking_internal_barrier(): Errno =
  pthread_barrier_wait(global_barrier)

# Statistics
# ----------------------------------------------------------------------------------

profile_extern_decl(run_task)
profile_extern_decl(enq_deq_task)
profile_extern_decl(send_recv_task)
profile_extern_decl(send_recv_req)
profile_extern_decl(idle)

var
  requests_sent{.threadvar.}, requests_handled{.threadvar.}: uint32
  requests_declined{.threadvar.}, tasks_sent{.threadvar.}: uint32
  tasks_split{.threadvar.}: uint32

when defined(StealBackoff):
  # TODO: add to compilation flags list
  var requests_resent{.threadvar.}: uint32
when StealStrategy == StealKind.adaptative:
  var requests_steal_one{.threadvar.}: uint32
  var requests_steal_half{.threadvar.}: uint32
when defined(LazyFutures):
  var futures_converted{.threadvar.}: uint32


proc tasking_internal_statistics() =
  Master:
    printf"\n"
    printf"+========================================+\n"
    printf"|  Per-worker statistics                 |\n"
    printf"+========================================+\n"

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

proc worker_entry_fn(id: ptr int32): pointer {.noconv.} =
  ID = id[]
  set_current_task(nil)
  num_tasks_exec = 0
  tasking_finished = false

  # RT_init()
  discard tasking_internal_barrier()

  # TODO: Question td_sync barrier

  # RT_schedule()
  discard tasking_internal_barrier()
  tasking_internal_statistics()
  # RT_exit()

  return nil

# Init tasking system
# ----------------------------------------------------------------------------------

proc tasking_internal_init() =
  # TODO detect hyper-threading

  if existsEnv"WEAVE_NUM_THREADS":
    # num_workers is a global
    num_workers = getEnv"WEAVE_NUM_THREADS".parseInt.int32
    if num_workers <= 0:
      raise newException(ValueError, "WEAVE_NUM_THREADS must be > 0")
    elif num_workers > MaxWorkers:
      printf "WEAVE_NUM_THREADS is truncated to %d\n", MaxWorkers
  else:
    num_workers = countProcessors().int32

  # TODO Question, why the convoluted cpu_count()
  # when countProcessors / sysconf(_SC_NPROCESSORS_ONLN)
  # is easy
  #
  # Call cpu_count() only once, before changing the affinity of thread 0!
  # After set_thread_affinity(0), cpu_count() would return 1, and every
  # thread would end up being pinned to processor 0.
  let num_cpus {.global.} = cpu_count()
  printf "Number of CPUs: %d\n", num_cpus

  when defined(DISABLE_MANAGER):
    # Global - Reserve cache lines to avoid false sharing
    td_count = cast[ptr Atomic[int32]](malloc(Atomic[int32], 64))
    store(td_count[], 0, moRelaxed)

  IDs = malloc(int32, num_workers)
  worker_threads = malloc(Pthread, num_workers)

  discard pthread_barrier_init(global_barrier, nil, num_workers)

  # Master thread
  ID = 0
  IDs[0] = 0

  # Bind master thread to CPU 0
  set_thread_affinity(0)

  # Create num_workers-1 worker threads
  for i in 1 ..< num_workers:
    IDs[i] = i
    discard pthread_create(worker_threads[i], nil, worker_entry_fn, IDs[i].addr)
    # Bind worker threads to available CPUs in a round-robin fashion
    # TODO take into account 2x and 4x Hyper Threading (Xeon Phi)
    set_thread_affinity(worker_threads[i], i mod num_cpus)

    set_current_task(task_new())

    num_tasks_exec = 0
    tasking_finished = false

# Teardown tasking system
# ----------------------------------------------------------------------------------

proc notify_workers() =
  # TODO - no implementation
  discard

proc tasking_internal_exit_signal() =
  notify_workers()
  tasking_finished = true

proc tasking_internal_exit() =
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

proc tasking_done(): bool =
  return tasking_finished
