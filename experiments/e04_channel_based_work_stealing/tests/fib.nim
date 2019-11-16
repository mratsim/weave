import
  # STD lib
  os, strutils,
  # Internal
  ../async_internal,
  ../profile,
  ../runtime,
  ../primitives/c,
  ../tasking,
  # bench
  ./wtime

proc parfib(n: uint64): uint64 =
  if n < 2:
    return n

  let x = async parfib(n-1)
  let y = parfib(n-2)

  return await(x) + y

proc main() =
  if paramCount() != 1:
    echo "Usage: fib <n-th fibonacci number requested>"
    quit 0

  let n = paramStr(1).parseUInt.uint64

  tasking_init()

  let start = Wtime_msec()
  let f = parfib(n)
  let stop = Wtime_msec()

  printf("Result: %d\n", f);
  printf("Elapsed wall time: %.2lf ms\n", stop-start);

  tasking_barrier()
  tasking_exit()

main()
