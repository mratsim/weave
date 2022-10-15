import
  # STD lib
  os, strutils, system/ansi_c, cpuinfo, strformat, math,
  # Library
  ../../weave,
  # bench
  ../wtime, ../resources

var
  Depth: int32 # For example 10000
  NumTasksPerDepth: int32 # For example 9
  # The total number of tasks in the BPC benchmark is
  # (NumTasksPerDepth + 1) * Depth
  NumTasksTotal: int32
  TaskGranularity: int32 # in microseconds
  PollInterval: float64  # in microseconds

var global_poll_elapsed {.threadvar.}: float64

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

proc bpc_consume(usec: int32) =

  var pollElapsed = 0'f64

  let start = wtime_usec()
  let stop = usec.float64
  global_poll_elapsed = PollInterval

  while true:
    var elapsed = wtime_usec() - start
    elapsed -= pollElapsed
    if elapsed >= stop:
      break

    dummy_cpt()

    if elapsed >= global_poll_elapsed:
      let pollStart = wtime_usec()
      loadBalance(Weave)
      pollElapsed += wtime_usec() - pollStart
      global_poll_elapsed += PollInterval

proc bpc_consume_nopoll(usec: int32) =

  let start = wtime_usec()
  let stop = usec.float64

  while true:
    var elapsed = wtime_usec() - start
    if elapsed >= stop:
      break

    dummy_cpt()

proc bpc_produce(n, d: int32) {.gcsafe.} =
  if d > 0:
    # Create producer task
    spawn bpc_produce(n, d-1)
  else:
    return

  # Followed by n consumer tasks
  for i in 0 ..< n:
    spawn bpc_consume(TaskGranularity)

proc main() =
  Depth = 10000
  NumTasksPerDepth = 999
  TaskGranularity = 1

  if paramCount() == 0:
    let exeName = getAppFilename().extractFilename()
    echo &"Usage: {exeName} <depth: {Depth}> " &
         &"<# of tasks per depth: {NumTasksPerDepth}> " &
         &"[task granularity (us): {TaskGranularity}] " &
         &"[polling interval (us): task granularity]"
    echo &"Running with default config Depth = {Depth}, NumTasksPerDepth = {NumTasksPerDepth}, granularity (us) = {TaskGranularity}, polling (us) = {PollInterval}"
  if paramCount() >= 1:
    Depth = paramStr(1).parseInt.int32
  if paramCount() >= 2:
    NumTasksPerDepth = paramStr(2). parseInt.int32
  if paramCount() >= 3:
    TaskGranularity = paramStr(3). parseInt.int32
  if paramCount() == 4:
    PollInterval = paramStr(4).parseInt.float64
  else:
    PollInterval = TaskGranularity.float64
  if paramCount() > 4:
    let exeName = getAppFilename().extractFilename()
    echo &"Usage: {exeName} <depth: {Depth}> " &
         &"<# of tasks per depth: {NumTasksPerDepth}> " &
         &"[task granularity (us): {TaskGranularity}] " &
         &"[polling interval (us): task granularity]"
    quit 1

  NumTasksTotal = (NumTasksPerDepth + 1) * Depth

  var nthreads: int
  if existsEnv"WEAVE_NUM_THREADS":
    nthreads = getEnv"WEAVE_NUM_THREADS".parseInt()
  else:
    nthreads = countProcessors()

  init(Weave)

  # measure overhead during tasking
  var ru: Rusage
  getrusage(RusageSelf, ru)
  var
    rss = ru.ru_maxrss
    flt = ru.ru_minflt

  let start = wtime_msec()

  bpc_produce(NumTasksPerDepth, Depth)
  syncRoot(Weave)

  let stop = wtime_msec()

  getrusage(RusageSelf, ru)
  rss = ru.ru_maxrss - rss
  flt = ru.ru_minflt - flt

  exit(Weave)

  const lazy = defined(WV_LazyFlowvar)
  const config = if lazy: " (lazy flowvars)"
                 else: " (eager flowvars)"

  echo "--------------------------------------------------------------------------"
  echo "Scheduler:                                     Weave", config
  echo "Benchmark:                                     BPC (Bouncing Producer-Consumer)"
  echo "Threads:                                       ", nthreads
  echo "Time(ms)                                       ", round(stop - start, 3)
  echo "Max RSS (KB):                                  ", ru.ru_maxrss
  echo "Runtime RSS (KB):                              ", rss
  echo "# of page faults:                              ", flt
  echo "--------------------------------------------------------------------------"
  echo "# of tasks:                                    ", NumTasksTotal
  echo "# of tasks/depth:                              ", NumTasksPerDepth
  echo "Depth:                                         ", Depth
  echo "Task granularity (us):                         ", TaskGranularity
  echo "Polling / manual load balancing interval (us): ", PollInterval

  quit 0

main()
