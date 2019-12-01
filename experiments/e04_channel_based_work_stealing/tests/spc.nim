import
  # STD lib
  os, strutils, strformat, cpuinfo, math,
  # Internal
  ../async_internal,
  ../profile,
  ../runtime,
  ../primitives/c,
  ../tasking,
  # bench
  ./wtime, ./resources

var NumTasksTotal: int32
var TaskGranularity: int32 # microsecond
var PollInterval: float64  # microsecond

proc print_usage() =
  # If not specified the polling interval is set to the value
  # of Task Granularity which effectively disables polling
  echo "Usage: spc <number of tasks> <task granularity (us)> " &
       "[polling interval (us)]"

profile_extern_decl(run_task)
profile_extern_decl(enq_deq_task)

var poll_elapsed {.threadvar.}: float64

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

  var RT_poll_elapsed = 0'f64

  let start = Wtime_usec()
  let stop = usec.float64
  poll_elapsed = PollInterval

  while true:
    var elapsed = Wtime_usec() - start
    elapsed = elapsed - RT_poll_elapsed # Somehow this shows up in VTune ...
    if elapsed >= stop:
      break

    dummy_cpt()

    if elapsed >= poll_elapsed:
      let RT_poll_start = Wtime_usec()
      RT_check_for_steal_requests()
      RT_poll_elapsed += Wtime_usec() - RT_poll_start
      poll_elapsed += PollInterval

  # printf("Elapsed: %.2lfus\n", elapsed)

proc spc_consume_nopoll(usec: int32) =

  let start = Wtime_usec()
  let stop = usec.float64

  while true:
    var elapsed = Wtime_usec() - start
    if elapsed >= stop:
      break

    dummy_cpt()

  # printf("Elapsed: %.2lfus\n", elapsed)

proc spc_produce(n: int32) =
  for i in 0 ..< n:
    async spc_consume(TaskGranularity)

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

  tasking_init()

  # measure overhead during tasking
  var ru: Rusage
  getrusage(RusageSelf, ru)
  var
    rss = ru.ru_maxrss
    flt = ru.ru_minflt

  let start = Wtime_msec()

  # spc_produce_seq(NumTasksTotal)
  spc_produce(NumTasksTotal)
  tasking_barrier()

  let stop = Wtime_msec()

  tasking_barrier()

  getrusage(RusageSelf, ru)
  rss = ru.ru_maxrss - rss
  flt = ru.ru_minflt - flt

  const lazy = defined(LazyFutures)
  const config = if lazy: " (lazy futures)"
                 else: " (eager futures)"

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


  tasking_exit() # At the end because sometimes the runtime gets stuck on exit

main()
