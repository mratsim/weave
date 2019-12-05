# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[sparsesets, sync_types, context_thread_local, binary_worker_trees],
  ./contexts, ./targets,
  ./instrumentation/[contracts, profilers, loggers],
  ./channels/[channels_mpsc_unbounded_batch, event_notifiers],
  ./memory/persistacks,
  ./config, ./signals,
  std/atomics

# Thief
# ----------------------------------------------------------------------------------

proc newStealRequest(): StealRequest {.inline.} =
  ## Create a new steal request
  ## This does not initialize the Thief state
  result = localCtx.stealCache.borrow()
  ascertain: result.victims.capacity.int32 == workforce()

  result.next.store(nil, moRelaxed)
  result.thiefAddr = myTodoBoxes.borrow()
  result.thiefID = myID()
  result.retry = 0
  result.victims.refill()
  result.victims.excl(myID())
  StealAdaptative:
    result.stealHalf = myThefts().stealHalf

# Synchronization
# ----------------------------------------------------------------------------------

proc rawSend(victimID: WorkerID, req: sink StealRequest) {.inline.}=
  ## Send a steal or work sharing request
  # TODO: check for race condition on runtime exit
  # log("Worker %2d: sending request 0x%.08x to %d (Channel: 0x%.08x)\n",
  #       myID(), cast[ByteAddress](req), victimID, globalCtx.com.thefts[victimID].addr)
  let stealRequestSent = globalCtx.com
                                  .thefts[victimID]
                                  .trySend(req)

  # The channel has a theoretical upper bound of
  # N steal requests (from N-1 workers + own request sent back)
  postCondition: stealRequestSent

proc relaySteal(victimID: WorkerID, req: sink StealRequest) {.inline.} =
  rawSend(victimID, req)

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

  # Already counted in outstanding
  incCounter(shareSent)

  metrics:
    StealAdaptative:
      if myThefts().stealHalf:
        incCounter(shareHalf)
      else:
        incCounter(shareOne)

proc findVictimAndSteal(req: sink StealRequest) =
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
  debug: log("Worker %2d: sending own steal request to %d (Channel 0x%.08x)\n",
    myID(), target, globalCtx.com.thefts[target].addr)
  target.sendSteal(req)

proc findVictimAndRelaySteal*(req: sink StealRequest) =
  # Note:
  #   Nim manual guarantees left-to-right function evaluation.
  #   Hence in the following:
  #     `req.findVictim().relaySteal(req)`
  #   findVictim request update should be done before relaySteal
  #
  #   but C and C++ do not provides that guarantee
  #   and debugging that in a multithreading runtime
  #   would probably be very painful.
  let target = findVictim(req)
  debug: log("Worker %2d: relay steal request from %d to %d (Channel 0x%.08x)\n",
    myID(), req.thiefID, target, globalCtx.com.thefts[target].addr)
  # TODO there seem to be a livelock here with the new queue and 16+ workers.
  #      activating the log above solves it.
  # The runtime gets stuck in declineAll/trySteal
  target.relaySteal(req)

# Stealing logic
# ----------------------------------------------------------------------------------

proc updateStealStrategy() =
  ## Estimate work-stealing efficiency during the last interval
  ## If the value is below a threshold, switch strategies
  if myThefts().recentThefts == WV_StealAdaptativeInterval:
    # Reevaluate the ratio of tasks processed within the theft interval
    let ratio = myThefts().recentTasks.float32 / float32(WV_StealAdaptativeInterval)
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
    if myThefts().outstanding < WV_MaxConcurrentStealPerWorker:
      StealAdaptative:
        updateStealStrategy()
      let req = newStealRequest()
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
  preCondition: myThefts().outstanding > 0

  myThefts().outstanding -= 1
  myTodoBoxes().recycle(req.thiefAddr)
  localCtx.stealCache.recycle(req)

proc drop*(req: sink StealRequest) =
  ## Removes a steal request from circulation
  ## Worker quota stays as-is for termination detection
  preCondition: req.thiefID == myID()
  preCondition: myThefts().outstanding > 1
  # Worker in Stealing state as it didn't reach
  # the concurrent steal request quota.
  preCondition: not myWorker().isWaiting

  debugTermination:
    log("Worker %2d drops steal request\n", myID)

  # A dropped request still counts in requests outstanding
  # don't decrement the count so that no new theft is initiated
  myThefts().dropped += 1
  myTodoBoxes().recycle(req.thiefAddr)
  localCtx.stealCache.recycle(req)

proc lastStealAttemptFailure*(req: sink StealRequest) =
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
      log("Worker %2d: sends state passively WAITING to its parent worker %d\n", myID(), myWorker().parent)
    sendShare(req)
    ascertain: not myWorker().isWaiting
    myWorker().isWaiting = true
    # myParking().wait() # Thread is blocked here until woken up.
