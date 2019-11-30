import
  # STD lib
  os, strutils, system/ansi_c,
  # Library
  ../../weave,
  # bench
  ../wtime

var NumTasksTotal: int32
var TaskGranularity: int32 # microsecond
var PollInterval: float64  # microsecond

proc print_usage() =
  # If not specified the polling interval is set to the value
  # of Task Granularity which effectively disables polling
  echo "Usage: spc <number of tasks> <task granularity (us)> " &
       "[polling interval (us)]"

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

  let start = Wtime_usec()
  let stop = usec.float64
  global_poll_elapsed = PollInterval

  while true:
    var elapsed = Wtime_usec() - start
    elapsed = elapsed - pollElapsed
    if elapsed >= stop:
      break

    dummy_cpt()

    if elapsed >= poll_elapsed:
      let pollStart = Wtime_usec()
      loadBalance(Weave)
      pollElapsed += Wtime_usec() - pollStart
      global_poll_elapsed += PollInterval

  # c_printf("Elapsed: %.2lfus\n", elapsed)

proc spc_consume_nopoll(usec: int32) =

  let start = Wtime_usec()
  let stop = usec.float64

  while true:
    var elapsed = Wtime_usec() - start
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
  if paramCount() notin 2..3:
    print_usage()
    quit 0

  NumTasksTotal = paramStr(1).parseInt.int32
  TaskGranularity = paramStr(2). parseInt.int32
  PollInterval = if paramCount() == 4: paramStr(3).parseInt.float64
                 else: TaskGranularity.float64

  init(Weave)

  let start = Wtime_msec()

  # spc_produce_seq(NumTasksTotal)
  spc_produce(NumTasksTotal)
  sync(Weave)

  let stop = Wtime_msec()

  c_printf("Elapsed wall time: %.2lf ms (%d us per task)\n", stop-start, TASK_GRANULARITY)

  sync(Weave)
  exit(Weave)

  quit 0

main()
