# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../instrumentation/[contracts, profilers, loggers],
  ../datatypes/[sync_types, prell_deques, context_thread_local, binary_worker_trees],
  ../contexts, ../config,
  ../victims,
  ../thieves,
  ./decline_thief, ./handle_thieves

proc nextTask*(childTask: static bool): Task {.inline.} =
  profile(enq_deq_task):
    if childTask:
      result = myWorker().deque.popFirstIfChild(myTask())
    else:
      result = myWorker().deque.popFirst()

  when WV_StealEarly > 0:
    if not result.isNil:
      # If we have a big loop should we allow early thefts?
      stealEarly()

  shareWork()

  # Check if someone requested to steal from us
  # Send them extra tasks if we have them
  # or split our popped task if possible
  handleThieves(result)

proc declineAll*() =
  var req: StealRequest

  profile_stop(idle)

  if recv(req):
    if req.thiefID == myID() and req.state == Working:
      req.state = Stealing
    decline(req)

  profile_start(idle)
