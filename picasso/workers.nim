# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./workstealing_types/[victims_bitsets, sync_types, context_thread_local, bounded_queues],
  ./runtime,
  ./instrumentation/[contracts, profilers, loggers],
  ./channels/channels_mpsc_bounded_lock,
  ./memory/intrusive_stacks,
  ./static_config

# Thief
# ----------------------------------------------------------------------------------

proc init(req: var StealRequest) {.inline.} =
  ## Initialize a steal request
  ## This does not initialize the Thief state
  req.taskChannel = localCtx.taskCache.pop()
  req.thiefID = localCtx.worker.ID
  req.retry = 0
  req.victims.init(globalCtx.numWorkers)
  req.victims.clear(localCtx.worker.ID)
  StealAdaptative:
    req.stealHalf: localCtx.thefts.stealHalf

proc send(victimID: WorkerID, req: sink StealRequest) {.inline.}=
  ## Send a steal or work sharing request
  # TODO: check for race condition on runtime exit
  let success = globalCtx.com.thievingChannels[victimID].trySend(req)

  # The channel has a theoretical upper bound of
  # N steal requests (from N-1 workers + own request sent back)
  postCondition: success

proc sendSteal(victimID: WorkerID, req: sink StealRequest) =
  ## Send a steal request and update context
  victimID.send(req)

  localCtx.thefts.requested += 1
  localCtx.counters.inc(stealsSent)

  metrics:
    StealAdaptative:
      if localCtx.thefts.stealHalf:
        localCtx.counters.inc(stealsHalf)
      else:
        localCtx.counters.inc(stealsOne)

proc updateStealStrategy() =
  ## Estimate work-stealing efficiency during the last interval
  ## If the value is below a threshold, switch strategies
  if localCtx.thefts.recentSteals == PicassoStealAdaptativeInterval:
    # Reevaluate the ratio of tasks processed within the theft interval
    let ratio = localCtx.thefts.recentTasks.float32 / float32(PicassoStealAdaptativeInterval)
    if localCtx.thefts.stealHalf and ratio < 2.0f:
      # Tasks stolen are coarse-grained, steal only one to reduce re-steals
      localCtx.thefts.stealHalf = false
    elif not(localCtx.thefts.stealHalf) and ratio == 1.0f:
      # All tasks processed were stolen tasks, we need to steal many at a time
      localCtx.thefts.stealHalf = true

    # Reset the interval
    localCtx.thefts.recentTasks = 0
    localCtx.thefts.recentSteals = 0

proc trySteal(outOfTasks: bool) =
  ## Try to send a steal request
  ## Every worker can have at most MaxSteal pending steal requests.
  ## A steal request with outOfTasks == false indicates that the
  ## requesting worker is still busy working on some tasks.
  ## A steal request with outOfTasks == true indicates that
  ## the requesting worker has run out of tasks.

  # For code size and improved cache usage
  # we don't use a static bool even though we could.
  profile(send_recv_req):
    if localCtx.thefts.requests < MaxStealAttempts:
      StealAdaptative:
        updateStealStrategy()
      var req: StealRequest
      req.init()
      if outOfTasks:
        req.state == Stealing
      else:
        req.state == Working

      # TODO LastVictim/LastThief
      req.nextVictim().sendSteal(req)

# Victim
# ----------------------------------------------------------------------------------

proc recv(req: var StealRequest): bool {.inline.} =
  profile(send_recv_req):
    result = globalCtx.com.thievingChannels[localCtx.worker.ID].tryRecv(req)

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
        ascertain: not localCtx.worker.isLeftIdle
        localCtx.worker.isLeftIdle = true
      else:
        ascertain: not localCtx.worker.isRightIdle
        localCtx.worker.isRightIdle = true
      # The child is now passive (work-sharing/sender-initiated/push)
      # instead of actively stealing (receiver-initiated/pull)
      # We keep its steal request for when we have more work.
      # while it backs off to save CPU
      localCtx.worker.workSharingRequests.enqueue(req)
      # Check the next steal request
      result = globalCtx.com.thievingChannels[localCtx.worker.ID].tryRecv(req)

  postCondition: not result or (result and req.state != Waiting)
