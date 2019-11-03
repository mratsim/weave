# 04 - port of https://epub.uni-bayreuth.de/2990/1/main_final.pdf
#
# Characteristics:
# - Message-passing based:
#   "Share memory by communicating instead of communicating by sharing."

import
  # stdlib
  os, strutils, times, strformat,
  # runtime
  ./e04_channel_based_work_stealing/[tasking, runtime, async_internal]

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

  let start = epochTime()
  let f = parfib(n)
  let stop = epochTime()

  echo &"Result: {f}"
  echo &"Elapsed wall time: {stop-start:2.6f} s"

  tasking_barrier()
  tasking_exit()

main()

# Compile with
