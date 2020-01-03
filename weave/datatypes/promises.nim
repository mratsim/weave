# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # stdlib
  atomics, locks,
  # Internals
  ../channels/[channels_spsc_single_ptr, loop_promises_notifiers],
  ../memory/[allocs, memory_pools],
  ../instrumentation/contracts,
  ../config

# Promises
# ----------------------------------------------------
# Promises are the counterpart to Flowvar.
#
# When a task depends on a promise, it is delayed until the promise is fulfilled
# This allows to model precise dependencies between tasks
# beyond what traditional control-flow dependencies (function calls, barriers, locks) allow.
#
# Furthermore control-flow dependencies like barriers and locks suffer from:
# - composability problem (barriers are incompatible with work stealing or nested parallelism).
# - restrict the parallelism exposed.
# - expose the programmers to concurrency woes that could be avoided
#   by specifying precede/after relationship
#
# Details, use-cases, competing approaches provided at: https://github.com/mratsim/weave/issues/31

type
  DummyPtr = ptr object

  Promise = object
    ## A promise is a placeholder for the input of a task.
    ## Tasks that depend on a promise are delayed until that
    ## promise is delivered.
    ##
    ## The difference with future/flowvar is that futures/flowvar
    ## represent a delayed result while promise represent a delayed input.
    p: PromisePtr

  PromisePtr = ptr object
    # Implementation: A promise is a write-once, broadcast SPMC channel.
    # The channel is intrusive and enforces WV_CacheLinePadding alignment
    chan{.align:WV_CacheLinePadding.}: ChannelSpscSinglePtr[DummyPtr]
    refCount: Atomic[int32]

const dummy = cast[DummyPtr](0xFACADE)

# TODO: do we need extra caching beyond the memory pool
#       like the lookaside list?

# Internal
# ----------------------------------------------------

# For now promises must be manually managed due to
# - https://github.com/nim-lang/Nim/issues/13024
# Additionally https://github.com/nim-lang/Nim/issues/13025
# requires workaround
#
# proc `=destroy`*(prom: var Promise) {.inline.} =
#   let oldCount = fetchSub(prom.p.refCount, 1, moRelease)
#   if oldCount == 1:
#     fence(moAcquire)
#     # Return memory to the memory pool
#     recycle(prom.p)
#
# proc `=`*(dst: var Promise, src: Promise) {.inline.}
#   # Workaround: https://github.com/nim-lang/Nim/issues/13025
#
# # Pending https://github.com/nim-lang/Nim/issues/13024
# proc `=sink`*(dst: var Promise, src: Promise) {.inline.} =
#   # Don't pay for atomic refcounting when compiler can prove there is no ref change
#   system.`=sink`(dst, src)
#
# proc `=`*(dst: var Promise, src: Promise) {.inline.} =
#   let oldCount = fetchAdd(src.p.refCount, 1, moRelaxed)
#   ascertain: oldCount > 0
#   system.`=`(dst, src)

func incRef*(prom: var Promise) {.inline.} =
  ## Manual atomic refcounting - workaround https://github.com/nim-lang/Nim/issues/13024
  let oldCount = fetchAdd(prom.p.refCount, 1, moRelaxed)
  ascertain: oldCount > 0

func decRef*(prom: var Promise) {.inline.} =
  ## Manual atomic refcounting - workaround https://github.com/nim-lang/Nim/issues/13024
  let oldCount = fetchSub(prom.p.refCount, 1, moRelease)
  ascertain: oldCount > 0
  if oldCount == 1:
    fence(moAcquire)
    # Return memory to the memory pool
    recycle(prom.p)

proc isFulfilled*(prom: Promise): bool {.inline.} =
  ## Check if a promise is fulfilled.
  # Library-only
  not prom.p.chan.isEmpty

# Public
# ----------------------------------------------------
# newPromise needs an extra wrapper that hides the pool allocator

proc newPromise*(pool: var TLPoolAllocator): Promise {.inline.} =
  ## Create a new promise.
  ## Promise allows to express fine-grain task dependencies
  ## Task dependent on promises will be delayed until it is fulfilled.
  result.p = pool.borrow(typeof result.p[])
  result.p.refCount.store(1, moRelaxed)

proc fulfill*(prom: Promise) {.inline.} =
  ## Deliver on a Promise
  ## Tasks dependent on this promise can now be scheduled.
  preCondition: not prom.p.isNil
  preCondition: prom.p.chan.isEmpty
  let wasDelivered = prom.p.chan.trySend(dummy)
  postCondition: wasDelivered

# Promise ranges
# ----------------------------------------------------
# A promise range is a generalization of promises
# to support a for-loop range

type
  ConsumerLoopPromises* = object
    ## A "consumer loop promises" object tracks the difference
    ## between what iterations of a for-loop are ready
    ## and what delayed tasks have yet to be scheduled
    # This is thread-local but keeps a reference
    # to the thread-safe producers broadcasting channels
    producers: ProducersLoopPromises
    dispatched: ptr UncheckedArray[int32]

proc newConsumerLoopPromises*(producers: ProducersLoopPromises): ConsumerLoopPromises =
  ## Create a new thread-local consumer of loop promises
  result.producers = producers
  result.dispatched = wv_alloc(int32, producers.lp.numBuckets)
  zeroMem(result.dispatched, sizeof(int32) * producers.lp.numBuckets)

proc dispatch(clp: ConsumerLoopPromises, bucket: int32) =
  ## Flag a task bucket as dispatched.
  var idx = bucket
  while idx != 0:
    clp.dispatched[idx] += 1
    idx = (idx-1) shr 1

  clp.dispatched[0] += 1

proc anyAvailable(clp: ConsumerLoopPromises, bucket: int32): bool {.inline.} =
  if bucket >= clp.producers.lp.numBuckets:
    return false
  let dispatched = clp.dispatched[bucket]
  let available = clp.producers.lp.fulfilled[bucket].load(moRelaxed)
  # fence(moAcquire) - TODO: I'm pretty sure this is not needed even on weak memory models.
  return available > dispatched

proc anyFulfilled*(clp: ConsumerLoopPromises): tuple[foundNew: bool, bucket: int32] =
  ## Searches for a fulfilled promise that wasn't already dispatchindexed.
  ## If one is found, it will be marked dispatched and its bucket will be returned.
  if not clp.anyAvailable(bucket = 0):
    return

  while true:
    # 3 cases (non-exclusive)
    #   1. there is an availability in the left subtree
    #   2. there is an availability in the right subtree
    #   3. the current node is available
    let left = 2*result.bucket + 1
    let right = left + 1
    if clp.anyAvailable(left):
      result.bucket = left
    elif clp.anyAvailable(right):
      result.bucket = right
    else: # The current node is available and none of the children are
      break

  # We found an available node, update the dispatch tree
  result.foundNew = true
  ascertain: result.bucket in 0 ..< clp.producers.lp.numBuckets
  clp.dispatch(result.bucket)

# Sanity checks
# ------------------------------------------------------------------------------
# TODO: multithreaded test cases, at least for correct destructors/memory reclamation
#       since SPMC broadcast channels can be tested with a single thread-local consumer.

when isMainModule:
  proc main() =
    # Promises can't be globals, Nim bug: https://github.com/nim-lang/Nim/issues/13024
    echo "Testing Loop promises (producer + Consumer)"

    var pool: TLPoolAllocator
    pool.initialize()

    var plp: ProducersLoopPromises
    plp.initialize(pool, 0, 10, 1)
    var clp = newConsumerLoopPromises(plp)

    block:
      let promise = clp.anyFulfilled()
      doAssert not promise.foundNew

    plp.ready(7)

    block:
      let promise = clp.anyFulfilled()
      doAssert promise.foundNew and promise.bucket == 7, "promise: " & $promise

    block:
      let promise = clp.anyFulfilled()
      doAssert not promise.foundNew

    plp.ready(2)
    plp.ready(0)

    block:
      let promise = clp.anyFulfilled()
      doAssert promise.foundNew and promise.bucket == 2, "promise: " & $promise

    plp.ready(3)
    plp.ready(4)

    block:
      let promise = clp.anyFulfilled()
      doAssert promise.foundNew and promise.bucket == 3, "promise: " & $promise

    block:
      let promise = clp.anyFulfilled()
      doAssert promise.foundNew and promise.bucket == 4, "promise: " & $promise

    block:
      let promise = clp.anyFulfilled()
      doAssert promise.foundNew and promise.bucket == 0, "promise: " & $promise

    block:
      let promise = clp.anyFulfilled()
      doAssert not promise.foundNew

  main()
