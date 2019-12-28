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

func roundPrevMultipleOf(x: SomeInteger, step: SomeInteger): SomeInteger {.inline.} =
  ## Round the input to the previous multiple of "step"
  result = x - x mod step

func splitGuided(task: Task): int {.inline.} =
  ## Split iteration range based on the number of workers
  let stepsLeft = (task.stop - task.cur + task.stride-1) div task.stride
  preCondition: stepsLeft > 0

  {.noSideEffect.}:
    let numWorkers = workforce()
  let chunk = max(((task.stop - task.start + task.stride-1) div task.stride) div numWorkers, 1)
  if stepsLeft <= chunk:
    return task.splitHalf()
  return roundPrevMultipleOf(task.stop - chunk*task.stride, task.stride)

func splitAdaptative(task: Task, approxNumThieves: int32): int {.inline.} =
  ## Split iteration range based on the number of steal requests
  let stepsLeft = (task.stop - task.cur + task.stride-1) div task.stride
  preCondition: stepsLeft > 1

  debug:
    log("Worker %2d: %ld steps left (start: %d, current: %d, stop: %d, stride: %d, %d thieves)\n",
      myID(), stepsLeft, task.start, task.cur, task.stop, task.stride, approxNumThieves)

  # Send a chunk of work to all
  let chunk = max(stepsLeft div (approxNumThieves + 1), 1)

  postCondition:
    stepsLeft > chunk

  result = roundPrevMultipleOf(task.stop - chunk*task.stride, task.stride)

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
