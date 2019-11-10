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
  ./static_config,
  ./thieves

# Worker
# ----------------------------------------------------------------------------------

proc recv(req: var StealRequest): bool {.inline.} =
  ## Check the worker theft channel
  ## for thieves.
  ##
  ## Updates req and returns true if a StealRequest was found

  profile(send_recv_req):
    result = globalCtx.com.thefts[localCtx.worker.ID].tryRecv(req)

    # We treat specially the case where children fail to steal
    # and defer to the current worker (their parent)
    while result and req.state == Waiting:
      debugTermination:
        log("Worker %d receives STATE_FAILED from worker %d\n",
            localCtx.worker.ID, req.thiefID)

      # Only children can forward a request where they sleep
      ascertain: req.thiefID == localCtx.worker.left or
                 req.thiefID == localCtx.worker.right
      if req.thiefID == localCtx.worker.left:
        ascertain: not localCtx.worker.isLeftWaiting
        localCtx.worker.isLeftWaiting = true
      else:
        ascertain: not localCtx.worker.isRightWaiting
        localCtx.worker.isRightWaiting = true
      # The child is now passive (work-sharing/sender-initiated/push)
      # instead of actively stealing (receiver-initiated/pull)
      # We keep its steal request for when we have more work.
      # while it backs off to save CPU
      localCtx.worker.workSharingRequests.enqueue(req)
      # Check the next steal request
      result = globalCtx.com.thefts[localCtx.worker.ID].tryRecv(req)

  postCondition: not result or (result and req.state != Waiting)

proc restartWork() =
  preCondition: localCtx.thefts.requested == PicassoMaxStealsOutstanding
  preCondition: myTodoBoxes().len == PicassoMaxStealsOutstanding

  # Adjust value of requested by MaxSteal-1, the number of steal
  # requests that have been dropped:
  # requested = requested - (MaxSteal-1) =
  #           = MaxSteal - MaxSteal + 1 = 1

  localCtx.thefts.requested = 1 # The current steal request is nut fully fulfilled yet
  localCtx.worker.isWaiting = false
  localCtx.thefts.dropped = 0

proc recv(task: var Task, isOutOfTasks: bool): bool =
  ## Check the worker task channel for a task successfully stolen
  ##
  ## Updates task and returns true if a task was found

  # Note we could use a static bool for isOutOfTasks but this
  # increase the code size.
  profile(send_recv_task):
    for i in 0 ..< PicassoMaxStealsOutstanding:
      result = myTodoBoxes.access(i)
                          .tryRecv(task)
      if result:
        # TODO: Recycle the channel for a future steal request
        # localCtx.taskChannelPool.recycle(task)
        debug:
          log("Worker %d received a task with function address %d\n", localCtx.worker.ID, task.fn)
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
        if localCtx.thefts.dropped > 0:
          ascertain: localCtx.thefts.requested > localCtx.thefts.dropped
          localCtx.thefts.requested -= localCtx.thefts.dropped
          localCtx.thefts.dropped = 0

    # Steal request fulfilled
    localCtx.thefts.requested -= 1

    postCondition: localCtx.thefts.requested in 0 ..< PicassoMaxStealsOutstanding
    postCondition: localCtx.thefts.dropped == 0
