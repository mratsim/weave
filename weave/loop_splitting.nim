# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./config, ./contexts,
  ./datatypes/sync_types,
  ./instrumentation/[contracts, loggers]

# Loop splitting
# ----------------------------------------------------------------------------------

# Adaptative loop-splitting depending on workload allows
# efficient load-balancing:
# - Loops are plit only when a worker is idle
# - Otherwise they stay on the worker optimizing cache reuse
#   and minimizing useless scheduler overhead

func splitHalf(task: Task): int {.inline.} =
  ## Split loop iteration range in half
  task.cur + ((task.stop - task.cur + task.stride-1) div task.stride) shr 1

# TODO: removed - https://github.com/aprell/tasking-2.0/commit/61068370282335802c07fcbc6bab3c9904c8ee4b
#
# func splitGuided(task: Task): int {.inline.} =
#   ## Split iteration range based on the number of workers
#   let itersLeft = abs(task.stop - task.cur)
#
#   preCondition: task.chunks > 0
#   preCondition: itersLeft > task.splitThreshold
#
#   if itersLeft <= task.chunks:
#     return task.splitHalf()
#
#   debug: log("Worker %2d: sending %ld iterations\n", myID(), task.chunks)
#   return task.stop - task.chunks

func roundPrevMultipleOf(x: SomeInteger, step: SomeInteger): SomeInteger {.inline.} =
  ## Round the input to the previous multiple of "step"
  result = x - x mod step

func splitAdaptative(task: Task, approxNumThieves: int32): int {.inline.} =
  ## Split iteration range based on the number of steal requests
  let itersLeft = (task.stop - task.cur + task.stride-1) div task.stride
  preCondition: itersLeft > 1

  debug:
    log("Worker %2d: %ld iterations left (start: %d, current: %d, stop: %d, stride: %d, %d thieves)\n",
      myID(), iters_left, task.start, task.cur, task.stop, task.stride, approxNumThieves)

  # Send a chunk of work to all
  let chunk = max(itersLeft div (approxNumThieves + 1), 1)

  postCondition:
    itersLeft > chunk

  debug: log("Worker %2d: sending %ld iterations\n", myID(), chunk*task.stride)
  return roundPrevMultipleOf(task.stop - chunk*task.stride, chunk*task.stride)

template split*(task: Task, approxNumThieves: int32): int =
  when SplitStrategy == SplitKind.half:
    splitHalf(task)
  elif SplitStrategy == guided:
    splitGuided(task)
  elif SplitStrategy == SplitKind.adaptative:
    splitAdaptative(task, approxNumThieves)
  else:
    {.error: "Unreachable".}

template isSplittable*(t: Task): bool =
  not t.isNil and t.isLoop and (t.stop - t.cur + t.stride-1) div t.stride > 1
