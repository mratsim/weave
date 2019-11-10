# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[sync_types, context_thread_local, bounded_queues],
  ./contexts,
  ./instrumentation/[contracts, profilers],
  ./channels/[channels_mpsc_bounded_lock, channels_spsc_single],
  ./memory/persistacks,
  ./config,
  ./thieves

# Worker - Tasks handling
# ----------------------------------------------------------------------------------

proc restartWork() =
  preCondition: myThefts().requested == PicassoMaxStealsOutstanding
  preCondition: myTodoBoxes().len == PicassoMaxStealsOutstanding

  # Adjust value of requested by MaxSteal-1, the number of steal
  # requests that have been dropped:
  # requested = requested - (MaxSteal-1) =
  #           = MaxSteal - MaxSteal + 1 = 1

  myThefts().requested = 1 # The current steal request is not fully fulfilled yet
  localCtx.worker.isWaiting = false
  myThefts().dropped = 0

proc recv(task: var Task, isOutOfTasks: bool): bool =
  ## Check the worker task channel for a task successfully stolen
  ##
  ## Updates task and returns true if a task was found

  # Note we could use a static bool for isOutOfTasks but this
  # increase the code size.
  profile(send_recv_task):
    for i in 0 ..< PicassoMaxStealsOutstanding:
      result = myTodoBoxes().access(i)
                            .tryRecv(task)
      if result:
        myTodoBoxes().nowAvailable(i)
        debug: log("Worker %d received a task with function address %d\n", myID(), task.fn)
        break

  if not result:
    trySteal(isOutOfTasks)
  else:
    when PicassoMaxStealsOutstanding == 1:
      if localCtx.worker.isWaiting:
        restartWork()
    else: # PicassoMaxStealsOutstanding > 1
      if localCtx.worker.isWaiting:
        restartWork()
      else:
        # If we have dropped one or more steal requests before receiving
        # tasks, adjust requested to make sure that we can send MaxSteal
        # steal requests again
        if myThefts().dropped > 0:
          ascertain: myThefts().requested > myThefts().dropped
          myThefts().requested -= myThefts().dropped
          myThefts().dropped = 0

    # Steal request fulfilled
    myThefts().requested -= 1

    postCondition: myThefts().requested in 0 ..< PicassoMaxStealsOutstanding
    postCondition: myThefts().dropped == 0
