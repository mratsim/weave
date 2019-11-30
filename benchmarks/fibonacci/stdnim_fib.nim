import
  # STD lib
  os, strutils, threadpool, strformat,
  # bench
  ../wtime

# Using Nim's standard threadpool
# Compile with "nim c --threads:on -d:release -d:danger --outdir:build benchmarks/fibonacci/stdnim_fib.nim"
#
# Note: it breaks at fib 16.

proc parfib(n: uint64): uint64 =
  if n < 2:   # Note: be sure to compare n<2 -> return n
    return n #       instead of n<=2 -> return 1

  let x = spawn parfib(n-1)
  let y = parfib(n-2)

  return ^x + y

proc main() =
  if paramCount() != 1:
    echo "Usage: fib <n-th fibonacci number requested>"
    quit 0

  let n = paramStr(1).parseUInt.uint64

  let start = wtime_msec()
  let f = parfib(n)
  let stop = wtime_msec()

  echo "Result: ", f
  echo &"Elapsed wall time: {stop-start:.2} ms"

main()
