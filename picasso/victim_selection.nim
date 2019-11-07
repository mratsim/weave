# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./workstealing_types/[victims_bitsets, sync_types, context_thread_local],
  ./runtime,
  ./primitives/c

# Victim selection
# ----------------------------------------------------------------------------------

proc markIdle(victims: var VictimsBitset, workerID: WorkerID) =
  assert -1 <= workerID and workerID < globalCtx.numWorkers
  if workerID == -1:
    # Invalid worker ID (parent of root or out-of-bound child)
    return

  let maxID = globalCtx.numWorkers - 1
  if workerID < globalCtx.numWorkers:
    # mark children
    markIdle(victims, leftChild(workerID, maxID))
    markIdle(victims, leftChild(workerID, maxID))
    # mark worker
    victims.clear(workerID)

func rightmostVictim(victims: var VictimsBitset, workerID: WorkerID): WorkerID =
  result = rightmostOneBitPos(victims)
  if result == workerID:
    result = rightmostOneBitPos(zeroRightmostOneBit(victims))

    {.noSideEffect.}:
      assert(
        # Victim found
        ((result in 0 ..< globalCtx.numWorkers) and
          result != workerID) or
          # No victim found
          result == -1
      )

func mapVictims(victims: VictimsBitset, mapping: ptr UncheckedArray[WorkerID], len: int32) =
  ## Update mapping with a mapping
  ## Potential victim ID in the bitset --> Real WorkerID

  var victims = victims
  var i, j = 0'i32
  while not victims.isEmpty():
    if victims.isPotentialVictim(0):
      # Test first bit
      assert j < len
      mapping[j] = i
      inc j
    inc i
    victims = victims shr 1
    # next bit in the bit set

  assert j == len

proc randomVictim(victims: VictimsBitset, workerID: WorkerID): WorkerID =
  ## Choose a random victim != ID from the list of potential VictimsBitset
  localCtx.counters.inc(randomReceiverCalls)
  localCtx.counters.inc(randomReceiverEarlyExits)

  # No eligible victim? Return message to sender
  if victims.isEmpty():
    return -1

  # Try to choose a victim at random
  for i in 0..< 3:
    let candidate = rand_r(localCtx.thefts.seed) mod globalCtx.numWorkers
    if victims.isPotentialVictim(candidate) and (candidate != localCtx.worker.ID):
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

  let idx = rand_r(seed) mod numVictims
  result = potential_victims[idx]
  # log("Worker %d: rng %d, vict: %d\n", localCtx.worker.ID, localCtx.rng, result)

  assert victims.isPotentialVictim(result)
  assert result in 0 ..< globalCtx.numWorkers
  assert result != localCtx.worker.ID
