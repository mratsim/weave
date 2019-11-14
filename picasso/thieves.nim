# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[victims_bitsets, sync_types, context_thread_local],
  ./contexts, ./targets,
  ./instrumentation/[contracts, profilers],
  ./channels/channels_mpsc_bounded_lock,
  ./memory/persistacks,
  ./config, ./signals

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

# Synchronization
# ----------------------------------------------------------------------------------

proc rawSend(victimID: WorkerID, req: sink StealRequest) {.inline.}=
  ## Send a steal or work sharing request
  # TODO: check for race condition on runtime exit
  let stealRequestSent = globalCtx.com
                                  .thefts[victimID]
                                  .trySend(req)

  # The channel has a theoretical upper bound of
  # N steal requests (from N-1 workers + own request sent back)
  postCondition: stealRequestSent

proc sendSteal(victimID: WorkerID, req: sink StealRequest) =
  ## Send a steal request
  victimID.rawSend(req)

  myThefts().outstanding += 1
  incCounter(stealSent)

  metrics:
    StealAdaptative:
      if myThefts().stealHalf:
        incCounter(stealHalf)
      else:
        incCounter(stealOne)

proc sendShare*(req: sink StealRequest) =
  ## Send a work sharing request to parent
  myWorker().parent.rawSend(req)

  myThefts().outstanding += 1
  incCounter(shareSent)

  metrics:
    StealAdaptative:
      if myThefts().stealHalf:
        incCounter(shareHalf)
      else:
        incCounter(shareOne)

proc findVictimAndSteal*(req: sink StealRequest) =
  # Note:
  #   Nim manual guarantees left-to-right function evaluation.
  #   Hence in the following:
  #     `req.findVictim().sendSteal(req)`
  #   findVictim request update should be done before sendSteal
  #
  #   but C and C++ do not provides that guarantee
  #   and debugging that in a multithreading runtime
  #   would probably be very painful.
  let target = findVictim(req)
  target.sendSteal(req)

# Stealing logic
# ----------------------------------------------------------------------------------

proc updateStealStrategy() =
  ## Estimate work-stealing efficiency during the last interval
  ## If the value is below a threshold, switch strategies
  if myThefts().recentThefts == PI_StealAdaptativeInterval:
    # Reevaluate the ratio of tasks processed within the theft interval
    let ratio = myThefts().recentTasks.float32 / float32(PI_StealAdaptativeInterval)
    if myThefts().stealHalf and ratio < 2.0f:
      # Tasks stolen are coarse-grained, steal only one to reduce re-steal
      myThefts().stealHalf = false
    elif not(myThefts().stealHalf) and ratio == 1.0f:
      # All tasks processed were stolen tasks, we need to steal many at a time
      myThefts().stealHalf = true

    # Reset the interval
    myThefts().recentTasks = 0
    myThefts().recentThefts = 0

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
    if myThefts().outstanding < PI_MaxConcurrentStealPerWorker:
      StealAdaptative:
        updateStealStrategy()
      var req: StealRequest
      req.init()
      if isOutOfTasks:
        req.state = Stealing
      else:
        req.state = Working

      # TODO LastVictim/LastThief
      req.findVictimAndSteal()

proc forget*(req: sink StealRequest) =
  ## Removes a steal request from circulation
  ## Re-increment the worker quota

  preCondition: req.thiefID == myID()
  preCondition: myThefts().outstanding > 1

  myThefts().outstanding -= 1
  myTodoBoxes().recycle(req.thiefAddr)

proc drop*(req: sink StealRequest) =
  ## Removes a steal request from circulation
  ## Worker quota stays as-is for termination detection
  preCondition: req.thiefID == myID()
  preCondition: myThefts().outstanding > 1
  # Worker in Stealing state as it didn't reach
  # the concurrent steal request quota.
  preCondition: not myWorker().isWaiting

  debugTermination:
    log("Worker %d drops steal request\n", myID)

  # A dropped request still counts in requests outstanding
  # don't decrement the count so that no new theft is initiated
  myThefts().dropped += 1
  myTodoBoxes().recycle(req.thiefAddr)

proc lastStealAttempt*(req: sink StealRequest) =
  ## If it's the last theft attempt per emitted steal requests
  ## - if we are the lead thread, we know that every other threads are idle/waiting for work
  ##   but there is none --> termination
  ## - if we are a worker thread, we message our parent and
  ##   passively wait for it to send us work or tell us to shutdown.

  if myID() == LeaderID:
    detectTermination()
    forget(req)
  else:
    req.state = Waiting
    debugTermination:
      log("Worker %d sends state passively WAITING to its parent worker %d\n", myID(), myWorker().parent)
    sendShare(req)
    ascertain: not myWorker().isWaiting
    myWorker().isWaiting = true
