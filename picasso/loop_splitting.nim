# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./contexts,
  ./config,
  ./datatypes/sync_types,
  ./instrumentation/contracts

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

func splitAdaptative(task: Task): int {.inline.} =
  ## Split iteration range based on the number of steal requests
  let itersLeft = abs(task.stop - task.cur)
  preCondition: itersLeft > task.splitThreshold

  debug: log("Worker %2d: %ld of %ld iterations left\n", ID, iters_left, iters_total)

  # We estimate the number of idle workers by counting the number of theft attempts
  # Notes:
  #   - We peek into a MPSC channel from the consumer thread: the peek is a lower bound
  #     as more requests may pile up concurrently.
  #   - We already read 1 steal request before trying to split so need to add it back.
  #   - Workers may send steal requests before actually running out-of-work
  let approxNumThieves = 1 + myThieves
  debug: log("Worker %2d: has %ld steal requests\n", ID, approxNumThieves)

  # Send a chunk of work to all
  let chunk = max(itersLeft div (approxNumThieves + 1), 1)

  postCondition:
    itersLeft > chunk

  debug: log("Worker %2d: sending %ld iterations\n", ID, chunk)
  return task.stop - chunk

template dispatchSplit(task: Task): int =
  when SplitStrategy == SplitKind.half:
    splitHalf(task)
  elif SplitStrategy == guided:
    splitGuided(task)
  elif SplitStrategy == SplitKind.adaptative:
    splitAdaptative(task)
  else:
    {.error: "Unreachable".}
