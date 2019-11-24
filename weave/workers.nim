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

proc restartWork() =
  preCondition: myThefts().outstanding == WV_MaxConcurrentStealPerWorker
  preCondition: myTodoBoxes().len == WV_MaxConcurrentStealPerWorker

  # Adjust value of outstanding by MaxSteal-1, the number of steal
  # requests that have been dropped:
  # outstanding = outstanding - (MaxSteal-1) =
  #           = MaxSteal - MaxSteal + 1 = 1

  myThefts().outstanding = 1 # The current steal request is not fully fulfilled yet
  myWorker().isWaiting = false
  myThefts().dropped = 0

proc recv*(task: var Task, isOutOfTasks: bool): bool =
  ## Check the worker task channel for a task successfully stolen
  ##
  ## Updates task and returns true if a task was found

  # Note we could use a static bool for isOutOfTasks but this
  # increase the code size.
  profile(send_recv_task):
    for i in 0 ..< WV_MaxConcurrentStealPerWorker:
      result = myTodoBoxes().access(i)
                            .tryRecv(task)
      if result:
        myTodoBoxes().nowAvailable(i)
        localCtx.stealCache.nowAvailable(i)
        debug: log("Worker %d received a task with function address %d\n", myID(), task.fn)
        break

  if not result:
    trySteal(isOutOfTasks)
  else:
    when WV_MaxConcurrentStealPerWorker == 1:
      if myWorker().isWaiting:
        restartWork()
    else: # WV_MaxConcurrentStealPerWorker > 1
      if myWorker().isWaiting:
        restartWork()
      else:
        # If we have dropped one or more steal requests before receiving
        # tasks, adjust outstanding to make sure that we can send MaxSteal
        # steal requests again
        if myThefts().dropped > 0:
          ascertain: myThefts().outstanding > myThefts().dropped
          myThefts().outstanding -= myThefts().dropped
          myThefts().dropped = 0

    # Steal request fulfilled
    myThefts().outstanding -= 1

    debug: log("Worker %d: %d theft(s) outstanding after receiving a task\n", myID(), myThefts().outstanding)
    postCondition: myThefts().outstanding in 0 ..< WV_MaxConcurrentStealPerWorker
    postCondition: myThefts().dropped == 0

proc run*(task: Task) {.inline.} =
  preCondition: not task.fn.isNil

  # TODO - logic seems sketchy, why do we do this <-> task.
  let this = myTask()
  myTask() = task
  task.fn(task.data.addr)
  myTask() = this
  metrics:
    if task.isLoop:
      # We have executed |stop-start| iterations
      incCounter(tasksExec, abs(task.stop - task.start))
    else:
      incCounter(tasksExec)
