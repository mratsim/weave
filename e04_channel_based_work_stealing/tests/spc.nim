import
  # STD lib
  times, os, strutils,
  # Internal
  ../async_internal,
  ../profile,
  ../runtime,
  ../primitives/c,
  ../tasking

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

  let start = epochTime()
  let stop = usec.float64
  poll_elapsed = PollInterval

  while true:
    var elapsed = epochTime() - start
    elapsed -= RT_poll_elapsed
    if elapsed >= stop:
      break

    dummy_cpt()

    if elapsed >= poll_elapsed:
      let RT_poll_start = epochTime()
      RT_check_for_steal_requests()
      RT_poll_elapsed += epochTime() - RT_poll_start
      poll_elapsed += PollInterval

  # printf("Elapsed: %.2lfus\n", elapsed)

proc spc_consume_nopoll(usec: int32) =

  let start = epochTime()
  let stop = usec.float64

  while true:
    var elapsed = epochTime() - start
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
  if paramCount() notin 2..3:
    print_usage()
    quit 0

  NumTasksTotal = paramStr(1).parseInt.int32
  TaskGranularity = paramStr(2). parseInt.int32
  PollInterval = if paramCount() == 4: paramStr(3).parseInt.float64
                 else: TaskGranularity.float64

  tasking_init()

  let start = epochTime()

  # spc_produce_seq(NumTasksTotal)
  spc_produce(NumTasksTotal)
  tasking_barrier()

  let stop = epochTime()

  printf("Elapsed wall time: %.2lf ms (%d us per task)\n", stop-start, TASK_GRANULARITY)

  tasking_barrier()
  tasking_exit()

  quit 0

main()
