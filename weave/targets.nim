# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[sparsesets, sync_types, context_thread_local, binary_worker_trees],
  ./contexts,
  ./instrumentation/[contracts, loggers],
  ./config

{.push gcsafe.}

# Victim selection
# ----------------------------------------------------------------------------------

proc markIdle(victims: var SparseSet, workerID: WorkerID) =
  preCondition:
    -1 <= workerID and workerID < workforce()

  if workerID == Not_a_worker:
    return

  for w in traverseBreadthFirst(workerID, maxID()):
    victims.excl(w)

proc randomVictim(victims: SparseSet, workerID: WorkerID): WorkerID =
  ## Choose a random victim != ID from the list of potential VictimsBitset
  preCondition:
    myID() notin victims

  # No eligible victim? Return message to sender
  if victims.isEmpty():
    return Not_a_worker

  result = victims.randomPick(myThefts().rng)
  # debug: log("Worker %2d: rng %d, vict: %d\n", myID(), myThefts().rng, result)

  postCondition: result in victims
  postCondition: result in 0 ..< workforce()
  postCondition: result != myID()

proc findVictim*(req: var StealRequest): WorkerID =
  if req.retry == WV_MaxRetriesPerSteal:
    # Return steal request to thief
    # logVictims(req.victims, req.thiefID)
    result = req.thiefID
  else:
    # Forward steal request to a different worker if possible
    # Also pass along information on the workers we manage
    ascertain: (req.retry == 0 and req.thiefID == myID()) or
               (req.retry > 0 and req.thiefID != myID())
    if myWorker().leftIsWaiting and myWorker().rightIsWaiting:
      markIdle(req.victims, myID())
    elif myWorker().leftIsWaiting:
      markIdle(req.victims, myWorker().left)
    elif myWorker().rightIsWaiting:
      markIdle(req.victims, myWorker().right)

    ascertain: myID() notin req.victims
    when FirstVictim == LastVictim:
      if myThefts().lastVictim != Not_a_worker and myThefts().lastVictim in req.victims:
        result = myThefts().lastVictim
      else:
        result = randomVictim(req.victims, req.thiefID)
    elif FirstVictim == LastThief:
      if myThefts().lastThief != Not_a_worker and myThefts().lastThief in req.victims:
        result = myThefts().lastThief
      else:
        result = randomVictim(req.victims, req.thiefID)
    else:
      result = randomVictim(req.victims, req.thiefID)

  if result == Not_a_worker:
    # Couldn't find a victim. Return the steal request to the thief
    ascertain: req.victims.isEmpty()
    result = req.thiefID

    debug:
      log("Worker %2d: relay thief {%d} -> no victim after %d tries (%u victims left)\n",
        myID(), req.thiefID, req.retry, req.victims.len
      )
    # If no targets were found either the request originated from a coworker
    # and I was the last possible target.
    # or all threads but the main one are sleeping and it retrieved its own request
    # from one of the sleeper queues
    postCondition: result != myID() or (result == myID() and myID() == RootID)

  postCondition: result in 0 ..< workforce()
  postCondition: req.retry in 0 .. WV_MaxRetriesPerSteal
