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
        log("Worker %d receives STATE_FAILED from worker %d\n",
            myID(), req.thiefID)

      # Only children can forward a request where they sleep
      ascertain: req.thiefID == localCtx.worker.left or
                 req.thiefID == localCtx.worker.right
      if req.thiefID == localCtx.worker.left:
        ascertain: not localCtx.worker.leftIsWaiting
        localCtx.worker.leftIsWaiting = true
      else:
        ascertain: not localCtx.worker.rightIsWaiting
        localCtx.worker.rightIsWaiting = true
      # The child is now passive (work-sharing/sender-initiated/push)
      # instead of actively stealing (receiver-initiated/pull)
      # We keep its steal request for when we have more work.
      # while it backs off to save CPU
      localCtx.worker.workSharingRequests.enqueue(req)
      # Check the next steal request
      result = myThieves().tryRecv(req)

  postCondition: not result or (result and req.state != Waiting)

proc decline(req)
