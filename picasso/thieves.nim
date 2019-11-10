# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[victims_bitsets, sync_types, context_thread_local],
  ./contexts, ./victim_selection,
  ./instrumentation/[contracts, profilers],
  ./channels/channels_mpsc_bounded_lock,
  ./memory/persistacks,
  ./static_config

# Thief
# ----------------------------------------------------------------------------------

proc init(req: var StealRequest) {.inline.} =
  ## Initialize a steal request
  ## This does not initialize the Thief state
  req.thiefAddr = myTodoBoxes.borrow()
  req.thiefID = myID()
  req.retry = 0
  req.victims.init(workforce())
  req.victims.clear(myID())
  StealAdaptative:
    req.stealHalf = myThefts().stealHalf

proc send(victimID: WorkerID, req: sink StealRequest) {.inline.}=
  ## Send a steal or work sharing request
  # TODO: check for race condition on runtime exit
  let success = globalCtx.com
                         .thefts[victimID]
                         .trySend(req)

  # The channel has a theoretical upper bound of
  # N steal requests (from N-1 workers + own request sent back)
  postCondition: success

proc sendSteal(victimID: WorkerID, req: sink StealRequest) =
  ## Send a steal request and update context
  victimID.send(req)

  myThefts().requested += 1
  myMetrics().inc(stealsSent)

  metrics:
    StealAdaptative:
      if myThefts().stealHalf:
        myMetrics().inc(stealsHalf)
      else:
        myMetrics().inc(stealsOne)

proc updateStealStrategy() =
  ## Estimate work-stealing efficiency during the last interval
  ## If the value is below a threshold, switch strategies
  if myThefts().recentSteals == PicassoStealAdaptativeInterval:
    # Reevaluate the ratio of tasks processed within the theft interval
    let ratio = myThefts().recentTasks.float32 / float32(PicassoStealAdaptativeInterval)
    if myThefts().stealHalf and ratio < 2.0f:
      # Tasks stolen are coarse-grained, steal only one to reduce re-steals
      myThefts().stealHalf = false
    elif not(myThefts().stealHalf) and ratio == 1.0f:
      # All tasks processed were stolen tasks, we need to steal many at a time
      myThefts().stealHalf = true

    # Reset the interval
    myThefts().recentTasks = 0
    myThefts().recentSteals = 0

proc trySteal*(isOutOfTasks: bool) =
  ## Try to send a steal request
  ## Every worker can have at most MaxSteal pending steal requests.
  ## A steal request with isOutOfTasks == false indicates that the
  ## requesting worker is still busy working on some tasks.
  ## A steal request with isOutOfTasks == true indicates that
  ## the requesting worker has run out of tasks.

  # For code size and improved cache usage
  # we don't use a static bool even though we could.
  profile(send_recv_req):
    if myThefts().requested < PicassoMaxStealAttempts:
      StealAdaptative:
        updateStealStrategy()
      var req: StealRequest
      req.init()
      if isOutOfTasks:
        req.state = Stealing
      else:
        req.state = Working

      # TODO LastVictim/LastThief
      req.nextVictim().sendSteal(req)

proc forget(req: sink StealRequest) =
  preCondition: req.thiefID == myID()
  preCondition: myThefts().requested > 1

  myThefts().requested -= 1
  myTodoBoxes().recycle(req.thiefAddr)
