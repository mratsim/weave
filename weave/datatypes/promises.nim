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
  ../channels/[channels_spsc_single, channels_mpsc_unbounded_batch],
  ../memory/memory_pools,
  ../instrumentation/contracts

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

  Promise* = ptr object
    # The channel is intrusive and enforces WV_CacheLinePadding alignment
    chan{.align:WV_CacheLinePadding.}: ChannelSpscSinglePtr[DummyPtr]
    refCount: Atomic[int32]

const dummy = cast[DummyPtr](0xFACADE)

# TODO: do we need extra caching beyond the memory pool
#       like the lookaside list?

# Internal
# ----------------------------------------------------

proc isFulfilled*(prom: Promise): bool {.inline.} =
  ## Check if a promise is fulfilled.
  # Library-only
  not prom.chan.isEmpty

proc `=`*(dst: var Promise, src: Promise) {.inline.} =
  let oldCount = fetchAdd(src.refCount, 1, moRelaxed)
  ascertain: oldCount > 0
  system.`=`(dst, src)

proc `=destroy`*(prom: var Promise) {.inline.} =
  let oldCount = fetchSub(prom.refCount, 1, moRelease)
  if oldCount == 1:
    fetch(moAcquire)
    # Return memory to the memory pool
    recycle(prom)

# Public
# ----------------------------------------------------

proc newPromise*(pool: var TLPoolAllocator): Promise {.inline.} =
  ## Create a new promise.
  ## Promise allows to express fine-grain task dependencies
  ## Task dependent on promises will be delayed until it is fulfilled.
  pool.borrow(typeof result[])
  result.refCount.store(1, moRelaxed)

proc fulfill*(prom: Promise) {.inline.}:
  ## Deliver on a Promise
  ## Tasks dependent on this promise can now be scheduled.
  preCondition: not prom.isNil
  preCondition: prom.isEmpty
  let wasDelivered = chan.trySend(dummy)
  postCondition: wasDelivered

# Promise ranges
# ----------------------------------------------------
# A promise range is a generalization of promises
# to support a for-loop range
# It is necessary to use loop tiling to process
# large loops with dependencies (i.e. depends on tile [0, 32), [32, 64), ...)

type
  PackedPromises = object
    # A pack of 256 promises (WV_MemBlockSize) that
    # fit in a memory pool block.
    proms: array[WV_MemBlockSize, bool]

  PromiseRange* = ptr object
    ## A promise range allows expressing dependencies over a for-loop.
    ## A PromiseRange can at most express up to 7168 iteration dependencies
    ##
    ## For example you can express dependencies for
    ##
    ## parallelFor 0 ..< 7168:
    ##   ...
    ##
    ## or
    ##
    ## parallelFor 0 ..< 458752, stride = 64:
    ##   ...
    ##
    ## Use tiling to express dependencies on large loop ranges:
    ##
    ## const tileSize = 64
    ## parallelForStrided i in 0 ..< M, stride = tileSize:
    ##   for ii in i ..< min(i+tileSize, M):
    ##     ...
    ##
    ## Tiling significantly improve cache usage and compute locality
    ## also significantly diminishes scheduling overhead.

    # TODO: this is using shared-memory in a message-passing based runtime!
    # Max promises on 64-bit: (256 - 4*32) div 8 * 256 = 7168
    refCount: Atomic[int32]
    start: int
    stop: int   # Non-inclusive stop
    stride: int
    promises: array[(WV_MemBlockSize - 4*sizeof(int)) div sizeof(pointer), ptr PackedPromises]
