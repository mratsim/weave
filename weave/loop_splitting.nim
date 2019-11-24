# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./config,
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
  task.cur + (task.stop - task.cur) shr 1

func splitGuided(task: Task): int {.inline.} =
  ## Split iteration range based on the number of workers
  let itersLeft = abs(task.stop - task.cur)

  preCondition: task.chunks > 0
  preCondition: itersLeft > task.splitThreshold

  if itersLeft <= task.chunks:
    return task.splitHalf()

  debug: log("Worker %2d: sending %ld iterations\n", myID(), task.chunks)
  return task.stop - task.chunks

func splitAdaptative(task: Task, approxNumThieves: int32): int {.inline.} =
  ## Split iteration range based on the number of steal requests
  let itersLeft = abs(task.stop - task.cur)
  preCondition: itersLeft > task.splitThreshold

  debug: log("Worker %2d: %ld of %ld iterations left\n", myID(), iters_left, abs(task.stop - task.start))

  # Send a chunk of work to all
  let chunk = max(itersLeft div (approxNumThieves + 1), 1)

  postCondition:
    itersLeft > chunk

  debug: log("Worker %2d: sending %ld iterations\n", myID(), chunk)
  return task.stop - chunk

template split*(task: Task, approxNumThieves: int32): int =
  when SplitStrategy == SplitKind.half:
    splitHalf(task)
  elif SplitStrategy == guided:
    splitGuided(task)
  elif SplitStrategy == SplitKind.adaptative:
    splitAdaptative(task, approxNumThieves)
  else:
    {.error: "Unreachable".}

func isSplittable*(t: Task): bool =
  not t.isNil and t.isLoop and abs(t.stop - t.cur) > t.splitThreshold
