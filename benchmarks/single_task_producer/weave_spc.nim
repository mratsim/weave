import
  # STD lib
  os, strutils, system/ansi_c, cpuinfo, strformat, math,
  # Library
  ../../weave,
  # bench
  ../wtime, ../resources

var NumTasksTotal: int32
var TaskGranularity: int32 # microsecond
var PollInterval: float64  # microsecond

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

proc spc_consume(usec: int32) =

  var pollElapsed = 0'f64

  let start = wtime_usec()
  let stop = usec.float64
  global_poll_elapsed = PollInterval

  while true:
    var elapsed = wtime_usec() - start
    elapsed = elapsed - pollElapsed
    if elapsed >= stop:
      break

    dummy_cpt()

    if elapsed >= poll_elapsed:
      let pollStart = wtime_usec()
      loadBalance(Weave)
      pollElapsed += wtime_usec() - pollStart
      global_poll_elapsed += PollInterval

  # c_printf("Elapsed: %.2lfus\n", elapsed)

proc spc_consume_nopoll(usec: int32) =

  let start = wtime_usec()
  let stop = usec.float64

  while true:
    var elapsed = wtime_usec() - start
    if elapsed >= stop:
      break

    dummy_cpt()

  # c_printf("Elapsed: %.2lfus\n", elapsed)

proc spc_produce(n: int32) =
  for i in 0 ..< n:
    spawn spc_consume(TaskGranularity)

proc spc_produce_seq(n: int32) =
  for i in 0 ..< n:
    spc_consume_no_poll(TaskGranularity)

proc main() =
  NumTasksTotal = 1000000
  TaskGranularity = 10
  PollInterval = 10

  if paramCount() == 0:
    let exeName = getAppFilename().extractFilename()
    echo &"Usage: {exeName} <# of tasks:{NumTasksTotal}> " &
         &"<task granularity (us): {TaskGranularity}> " &
         &"[polling interval (us): task granularity]"
    echo &"Running with default config tasks = {NumTasksTotal}, granularity (us) = {TaskGranularity}, polling (us) = {PollInterval}"
  if paramCount() >= 1:
    NumTasksTotal = paramStr(1).parseInt.int32
  if paramCount() >= 2:
    TaskGranularity = paramStr(2). parseInt.int32
  if paramCount() == 4:
    PollInterval = paramStr(3).parseInt.float64
  else:
    PollInterval = TaskGranularity.float64
  if paramCount() > 4:
    let exeName = getAppFilename().extractFilename()
    echo &"Usage: {exeName} <# of tasks:{NumTasksTotal}> " &
         &"<task granularity (us): {TaskGranularity}> " &
         &"[polling interval (us): task granularity]"
    quit 1

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

  # spc_produce_seq(NumTasksTotal)
  spc_produce(NumTasksTotal)
  sync(Weave)

  let stop = wtime_msec()

  getrusage(RusageSelf, ru)
  rss = ru.ru_maxrss - rss
  flt = ru.ru_minflt - flt

  sync(Weave)
  exit(Weave)

  const lazy = defined(WV_LazyFlowvar)
  const config = if lazy: " (lazy flowvars)"
                 else: " (eager flowvars)"

  echo "--------------------------------------------------------------------------"
  echo "Scheduler:                                    Weave", config
  echo "Benchmark:                                    SPC (Single task Producer - multi Consumer)"
  echo "Threads:                                      ", nthreads
  echo "Time(ms)                                      ", round(stop - start, 3)
  echo "Max RSS (KB):                                 ", ru.ru_maxrss
  echo "Runtime RSS (KB):                             ", rss
  echo "# of page faults:                             ", flt
  echo "--------------------------------------------------------------------------"
  echo "# of tasks:                                   ", NumTasksTotal
  echo "Task granularity (us):                        ", TaskGranularity
  echo "Polling / manual load balacing interval (us): ", PollInterval

  quit 0

main()
