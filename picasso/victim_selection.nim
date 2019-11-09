# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./workstealing_types/[victims_bitsets, sync_types, context_thread_local],
  ./runtime,
  ./primitives/c,
  ./instrumentation/contracts

# Victim selection
# ----------------------------------------------------------------------------------

proc markIdle(victims: var VictimsBitset, workerID: WorkerID) =
  preCondition:
    -1 <= workerID and workerID < globalCtx.numWorkers

  if workerID == -1:
    # Invalid worker ID (parent of root or out-of-bound child)
    return

  let maxID = globalCtx.numWorkers - 1
  if workerID < globalCtx.numWorkers:
    # mark children
    markIdle(victims, left(workerID, maxID))
    markIdle(victims, right(workerID, maxID))
    # mark worker
    victims.clear(workerID)

func rightmostVictim(victims: var VictimsBitset, workerID: WorkerID): WorkerID =
  result = rightmostOneBitPos(victims)
  if result == workerID:
    result = rightmostOneBitPos(zeroRightmostOneBit(victims))

    postCondition: {.noSideEffect.}:
      # Victim found
      ((result in 0 ..< globalCtx.numWorkers) and
        result != workerID) or
        # No victim found

func mapVictims(victims: VictimsBitset, mapping: ptr UncheckedArray[WorkerID], len: int32) =
  ## Update mapping with a mapping
  ## Potential victim ID in the bitset --> Real WorkerID

  var victims = victims
  var i, j = 0'i32
  while not victims.isEmpty():
    if victims.isPotentialVictim(0):
      # Test first bit
      ascertain: j < len
      mapping[j] = i
      inc j
    inc i
    victims.shift1()
    # next bit in the bit set

  postCondition: j == len

proc randomVictim(victims: VictimsBitset, workerID: WorkerID): WorkerID =
  ## Choose a random victim != ID from the list of potential VictimsBitset
  preCondition:
    localCtx.worker.ID notin victims

  localCtx.counters.inc(randomReceiverCalls)
  localCtx.counters.inc(randomReceiverEarlyExits)

  # No eligible victim? Return message to sender
  if victims.isEmpty():
    return -1

  # Try to choose a victim at random
  for i in 0..< 3:
    let candidate = rand_r(localCtx.thefts.rng) mod globalCtx.numWorkers
    if candidate in victims:
      postCondition candidate != localCtx.worker.ID
      return candidate

  # We didn't early exit, i.e. not enough potential victims
  # for completely randomized selection
  localCtx.counters.dec(randomReceiverEarlyExits)

  # Length of array is upper-bounded by the PicassoMaxWorkers but
  # num_victims is likely less than that or we would
  # have found a victim above
  #
  # Unfortunaly VLA (Variable-Length-Array) are only available in C99
  # So we emulate them with alloca.
  #
  # num_victims is probably quite low compared to num_workers
  # i.e. 2 victims for a 16-core CPU hence we save a lot of stack.
  #
  # Heap allocation would make the system allocator
  # a multithreaded bottleneck on fine-grained tasks
  let numVictims = victims.len
  let potential_victims = alloca(int32, numVictims)
  victims.mapVictims(potentialVictims, numVictims)

  let idx = rand_r(localCtx.thefts.rng) mod numVictims
  result = potential_victims[idx]
  # log("Worker %d: rng %d, vict: %d\n", localCtx.worker.ID, localCtx.thefts.seed, result)

  postCondition result in victims
  postCondition result in 0 ..< globalCtx.numWorkers
  postCondition result != localCtx.worker.ID

proc nextVictim*(req: var StealRequest): WorkerID =
  preCondition:
    localCtx.worker.ID notin req.victims

  result = -1

  if req.thiefID == localCtx.worker.ID:
    # Steal request initiated by the current worker.
    # Send it to a random one
    ascertain: req.retry == 0
    result = rand_r(localCtx.thefts.rng) mod globalCtx.numWorkers
    while result == localCtx.worker.ID:
      result = rand_r(localCtx.thefts.rng) mod globalCtx.numWorkers
  elif req.retry == MaxStealAttempts:
    # Return steal request to thief
    # logVictims(req.victims, req.thiefID)
    result = req.thiefID
  else:
    # Forward steal request to a different worker if possible
    # Also pass along information on the workers we manage
    if localCtx.worker.isLeftIdle and localCtx.worker.isRightIdle:
      markIdle(req.victims, localCtx.worker.ID)
    elif localCtx.worker.isLeftIdle:
      markIdle(req.victims, localCtx.worker.left)
    elif localCtx.worker.isRightIdle:
      markIdle(req.victims, localCtx.worker.right)

    ascertain: localCtx.worker.ID notin req.victims
    result = randomVictim(req.victims, req.thiefID)

  if result == -1:
    # Couldn't find a victim. Return the steal request to the thief
    ascertain: req.victims.isEmpty()
    result = req.thiefID

    # log("%d -{%d}-> %d after %d tries (%u ones)\n",
    #   ID, req.ID, victim, req, retry, req.victims.len
    # )

  postCondition: result in 0 ..< globalCtx.numWorkers
  postCondition: result != localCtx.worker.ID
  postCondition: req.retry in 0 .. MaxStealAttempts
