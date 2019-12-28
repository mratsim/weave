# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[sync_types, context_thread_local],
  ./contexts,
  ./instrumentation/[contracts, profilers, loggers],
  ./channels/channels_spsc_single_ptr,
  ./memory/persistacks,
  ./config,
  ./thieves

# Worker - Tasks handling
# ----------------------------------------------------------------------------------

proc restartWork*() =
  preCondition: myThefts().outstanding == WV_MaxConcurrentStealPerWorker
  preCondition: myTodoBoxes().len == WV_MaxConcurrentStealPerWorker

  # Adjust value of outstanding by MaxSteal-1, the number of steal
  # requests that have been dropped:
  # outstanding = outstanding - (MaxSteal-1) =
  #           = MaxSteal - MaxSteal + 1 = 1

  myThefts().outstanding = 1 # The current steal request is not fully fulfilled yet
  myWorker().isWaiting = false
  myThefts().dropped = 0

proc runTask*(task: Task) {.inline, gcsafe.} =
  preCondition: not task.fn.isNil

  # TODO - logic seems sketchy, why do we do this <-> task.
  let this = myTask()
  myTask() = task
  debug: log("Worker %2d: running task.fn 0x%.08x\n", myID(), task.fn)
  task.fn(task.data.addr)
  myTask() = this
  if task.isLoop:
    # We have executed |stop-start| iterations, for now only support forward iterations
    ascertain: task.stop > task.start
    let chunks = (task.stop - task.start + task.stride-1) div task.stride
    StealAdaptative:
      myThefts().recentTasks += chunks.int32 # overflow?
    incCounter(tasksExec, chunks)
  else:
    StealAdaptative:
      myThefts().recentTasks += 1
    incCounter(tasksExec)
