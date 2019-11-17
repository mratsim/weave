# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[sparsesets, sync_types, context_thread_local],
  ./contexts,
  ./random/rng,
  ./instrumentation/[contracts, loggers],
  ./config,
  ./memory/allocs

# Victim selection
# ----------------------------------------------------------------------------------

proc markIdle(victims: var SparseSet, workerID: WorkerID) =
  preCondition:
    -1 <= workerID and workerID < workforce()

  if workerID == -1:
    # Invalid worker ID (parent of root or out-of-bound child)
    return

  preCondition: workerID notin victims

  let maxID = workforce() - 1
  if workerID < workforce():
    # mark children
    markIdle(victims, left(workerID, maxID))
    markIdle(victims, right(workerID, maxID))

proc randomVictim(victims: SparseSet, workerID: WorkerID): WorkerID =
  ## Choose a random victim != ID from the list of potential VictimsBitset
  preCondition:
    myID() notin victims

  incCounter(randomVictimCalls)

  # No eligible victim? Return message to sender
  if victims.isEmpty():
    return -1

  result = victims.randomPick(myThefts().rng)
  # debug: log("Worker %d: rng %d, vict: %d\n", myID(), myThefts().rng, result)

  postCondition: result in victims
  postCondition: result in 0 ..< workforce()
  postCondition: result != myID()

proc findVictim*(req: var StealRequest): WorkerID =
  preCondition:
    myID() notin req.victims

  result = -1

  if req.thiefID == myID():
    # Steal request initiated by the current worker.
    # Send it to a random one
    ascertain: req.retry == 0
    result = myThefts().rng.uniform(workforce())
    while result == myID():
      result = myThefts().rng.uniform(workforce())
  elif req.retry == WV_MaxRetriesPerSteal:
    # Return steal request to thief
    # logVictims(req.victims, req.thiefID)
    result = req.thiefID
  else:
    # Forward steal request to a different worker if possible
    # Also pass along information on the workers we manage
    if myWorker().leftIsWaiting and myWorker().rightIsWaiting:
      markIdle(req.victims, myID())
    elif myWorker().leftIsWaiting:
      markIdle(req.victims, myWorker().left)
    elif myWorker().rightIsWaiting:
      markIdle(req.victims, myWorker().right)

    ascertain: myID() notin req.victims
    result = randomVictim(req.victims, req.thiefID)

  if result == -1:
    # Couldn't find a victim. Return the steal request to the thief
    ascertain: req.victims.isEmpty()
    result = req.thiefID

    debug:
      log("Worker %d: relay thief {%d} -> no victim after %d tries (%u ones)\n",
        myID(), req.thiefID, req.retry, req.victims.len
      )

  postCondition: result in 0 ..< workforce()
  postCondition: result != myID()
  postCondition: req.retry in 0 .. WV_MaxRetriesPerSteal
