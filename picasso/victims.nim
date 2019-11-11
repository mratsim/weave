# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[sync_types, context_thread_local, bounded_queues, victims_bitsets],
  ./contexts,
  ./instrumentation/[contracts, profilers],
  ./channels/[channels_mpsc_bounded_lock, channels_spsc_single],
  ./memory/persistacks,
  ./config,
  ./thieves, ./targets

# Victims - Steal requests handling
# ----------------------------------------------------------------------------------

proc recv(req: var StealRequest): bool {.inline.} =
  ## Check the worker theft channel
  ## for thieves.
  ##
  ## Updates req and returns true if a StealRequest was found

  profile(send_recv_req):
    result = myThieves().tryRecv(req)

    # We treat specially the case where children fail to steal
    # and defer to the current worker (their parent)
    while result and req.state == Waiting:
      debugTermination:
        log("Worker %d receives state passively WAITING from its child worker %d\n",
            myID(), req.thiefID)

      # Only children can forward a request where they sleep
      ascertain: req.thiefID == myWorker().left or
                 req.thiefID == myWorker().right
      if req.thiefID == myWorker().left:
        ascertain: not myWorker().leftIsWaiting
        myWorker().leftIsWaiting = true
      else:
        ascertain: not myWorker().rightIsWaiting
        myWorker().rightIsWaiting = true
      # The child is now passive (work-sharing/sender-initiated/push)
      # instead of actively stealing (receiver-initiated/pull)
      # We keep its steal request for when we have more work.
      # while it backs off to save CPU
      myWorker().workSharingRequests.enqueue(req)
      # Check the next steal request
      result = myThieves().tryRecv(req)

  postCondition: not result or (result and req.state != Waiting)

proc decline(req: sink StealRequest) =
  ## Pass steal request to another worker
  ## or the manager if it's our own that came back
  preCondition: req.retry <= PI_MaxRetriesPerSteal

  req.retry += 1

  profile(send_recv_req):
    incCounter(stealDeclined)

    if req.thiefID == myID():
      # No one had jobs to steal
      ascertain: req.victims.isEmpty()
      ascertain: req.retry == PI_MaxRetriesPerSteal

      if req.state == Stealing and myWorker().leftIsWaiting and myWorker().rightIsWaiting:
        when PI_MaxConcurrentStealPerWorker == 1:
          # When there is only one concurrent steal request allowed, it's always the last.
          lastStealAttempt(req)
        else:
          # Is this the last theft attempt allowed per steal request?
          # - if so: lastStealAttempt special case (termination if lead thread, sleep if worker)
          # - if not: drop it and wait until we receive work or all out steal requests failed.
          if myThefts().outstanding == PI_MaxConcurrentStealPerWorker and
             myTodoBoxes().len == PI_MaxConcurrentStealPerWorker - 1:
            # "PI_MaxConcurrentStealPerWorker - 1" steal requests have been dropped
            # as evidenced by the corresponding channel "address boxes" being recycled
            ascertain: myThefts().dropped == PI_MaxConcurrentStealPerWorker - 1
            lastStealAttempt(req)
          else:
            drop(req)
      else:
        # Our own request but we still have work, so we reset it and recirculate.
        # This can only happen if workers are allowed to steal before finishing their tasks.
        when PI_StealEarly > 0:
          req.retry = 0
          req.victims.init(workforce)
          req.victims.clear(myID())
          req.findVictimAndSteal()
        else: # No-op in "-d:danger"
          postCondition: PI_StealEarly > 0 # Force an error
    else: # Not our own request
      req.findVictimAndSteal()
