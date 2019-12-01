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

proc parfib(n: uint64): uint64 =
  if n < 2:
    return n

  let x = async parfib(n-1)
  let y = parfib(n-2)

  return await(x) + y

proc main() =
  var n = 40'u64
  var nthreads: int

  if paramCount() == 0:
    let exeName = getAppFilename().extractFilename()
    echo &"Usage: {exeName} <n-th fibonacci number requested:{n}> "
    echo &"Running with default n = {n}"
  elif paramCount() == 1:
    n = paramStr(1).parseUInt.uint64
  else:
    let exeName = getAppFilename().extractFilename()
    echo &"Usage: fib <n-th fibonacci number requested:{n}>"
    quit 1

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
  let f = parfib(n)
  let stop = Wtime_msec()

  tasking_barrier()

  getrusage(RusageSelf, ru)
  rss = ru.ru_maxrss - rss
  flt = ru.ru_minflt - flt

  const lazy = defined(LazyFutures)
  const config = if lazy: " (lazy futures)"
                 else: " (eager futures)"

  echo "--------------------------------------------------------------------------"
  echo "Scheduler:                                    Proof-of-concept", config
  echo "Benchmark:                                    Fibonacci"
  echo "Threads:                                      ", nthreads
  echo "Time(ms)                                      ", round(stop - start, 3)
  echo "Max RSS (KB):                                 ", ru.ru_maxrss
  echo "Runtime RSS (KB):                             ", rss
  echo "# of page faults:                             ", flt
  echo "--------------------------------------------------------------------------"
  echo "n requested:                                  ", n
  echo "result:                                       ", f

  tasking_exit() # At the end because sometimes the runtime gets stuck on exit

main()
