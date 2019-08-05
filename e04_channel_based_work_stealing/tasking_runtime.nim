# Proc should be in tasking_internal
# but can't due to Nim very restricted recursive imports

import
  # Standard library
  os, strutils, cpuinfo,
  # Internal
  ./primitives/[c, threads],
  ./affinity,
  ./tasking_internal, ./task,
  ./runtime

# pthread_create initializer
# ----------------------------------------------------------------------------------

proc worker_entry_fn(id: ptr int32): pointer {.noconv.} =
  ID = id[]
  set_current_task(nil)
  num_tasks_exec = 0
  tasking_finished = false

  RT_init()
  discard tasking_internal_barrier()

  # TODO: Question td_sync barrier

  {.gcsafe.}: # ignore compiler gcsafe warning
    RT_schedule()
  discard tasking_internal_barrier()
  tasking_internal_statistics()
  RT_exit()

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

# Teardown runtime system
# ----------------------------------------------------------------------------------

proc tasking_internal_exit_signal() =
  notify_workers(nil)
  tasking_finished = true
