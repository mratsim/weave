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
