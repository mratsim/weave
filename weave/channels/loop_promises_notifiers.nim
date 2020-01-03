# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Stdlib
  std/atomics,
  # Internals
  ../config,
  ../memory/[allocs, memory_pools],
  ../instrumentation/contracts

# Producers' side
# ----------------------------------------------------

type
  ProducersLoopPromises* = object
    ## This is a concurrent binary array tree
    ## that holds promises over a for-loop range.
    ## The producers which fulfill a promise update this tree.
    ## Consumers have a read-only view of it.
    ##
    ## It can be viewed as a collection of write-once, broadcast SPMC channels
    # Implementation detail and design goal are explained in the companion markdown file
    # Indirection is needed as destructors can only be defined on objects
    lp*: ProducersLoopPromisesPtr

  ProducersLoopPromisesPtr = ptr object

    refCount{.align: WV_MemBlockSize.}: Atomic[int32]
    start*, stop*, stride*: int32
    fulfilled*: ptr UncheckedArray[Atomic[int32]]
    numBuckets*: int32

# For now promises must be manually managed due to
# - https://github.com/nim-lang/Nim/issues/13024
# Additionally https://github.com/nim-lang/Nim/issues/13025
# requires workaround
#
# proc `=destroy`*(prom: var ProducersLoopPromises) {.inline.} =
#   let oldCount = fetchSub(prom.lp.refCount, 1, moRelease)
#   ascertain: oldCount > 0
#   ascertain: not prom.lp.fulfilled.isNil
#   if oldCount == 1:
#     fence(moAcquire)
#     # Return memory
#     wv_free(prom.lp.fulfilled)
#
# proc `=`*(dst: var ProducersLoopPromises, src: ProducersLoopPromises) {.inline.}
#   # Workaround: https://github.com/nim-lang/Nim/issues/13025
#
# # Pending https://github.com/nim-lang/Nim/issues/13024
# proc `=sink`*(dst: var ProducersLoopPromises, src: ProducersLoopPromises) {.inline.} =
#   # Don't pay for atomic refcounting when compiler can prove there is no ref change.
#   system.`=sink`(dst, src)
#
# proc `=`*(dst: var ProducersLoopPromises, src: ProducersLoopPromises) {.inline.} =
#   let oldCount = fetchAdd(src.lp.refCount, 1, moRelaxed)
#   ascertain: oldCount > 0
#   system.`=`(dst, src)

func incRef*(prom: var ProducersLoopPromises) {.inline.} =
  ## Manual atomic refcounting - workaround https://github.com/nim-lang/Nim/issues/13024
  let oldCount = fetchAdd(prom.lp.refCount, 1, moRelaxed)
  ascertain: oldCount > 0

func decRef*(prom: var ProducersLoopPromises) {.inline.} =
  ## Manual atomic refcounting - workaround https://github.com/nim-lang/Nim/issues/13024
  let oldCount = fetchSub(prom.lp.refCount, 1, moRelease)
  ascertain: oldCount > 0
  ascertain: not prom.lp.fulfilled.isNil
  if oldCount == 1:
    fence(moAcquire)
    # Return memory
    wv_free(prom.lp.fulfilled)
    recycle(prom.lp)

proc initialize*(plp: var ProducersLoopPromises, pool: var TLPoolAllocator, start, stop, stride: int32) =
  ## Allocate loop promises (producer side)
  ## Multiple consumers can depend on the delivery of those promises
  ## This is thread-safe.
  preCondition: stop > start
  preCondition: stride > 0

  plp.lp = pool.borrow(typeof plp.lp[])
  plp.lp.refCount.store(1, moRelaxed)
  plp.lp.start = start
  plp.lp.stop = stop
  plp.lp.stride = stride

  plp.lp.numBuckets = (plp.lp.stop - plp.lp.start + plp.lp.stride-1) div plp.lp.stride
  plp.lp.fulfilled = wv_alloc(Atomic[int32], plp.lp.numBuckets)
  zeroMem(plp.lp.fulfilled, sizeof(int32) * plp.lp.numBuckets)
  # Do we need a caching scheme? The memory pool does not handle
  # array allocation so we rely on the system allocator.

proc getBucket*(pr: ProducersLoopPromises, index: int32): int32 {.inline.} =
  ## Convert a possibly offset and/or strided for-loop iteration index
  ## to a promise bucket in the range [0, num_iterations)
  ## suitable for storing promises and task metadata in a linear array.
  preCondition: index in pr.lp.start ..< pr.lp.stop
  result = (index - pr.lp.start) div pr.lp.stride

proc ready*(pr: ProducersLoopPromises, index: int32) =
  ## requires the public iteration index in [start, stop) range.
  ## Flag a loop iteration as ready.
  # The flag is propagated to the root of the tree
  # so that by looking at the root we can
  # see if a new promise was delivered upon in O(1) time.
  preCondition: index in pr.lp.start ..< pr.lp.stop
  var idx = pr.getBucket(index)

  while idx != 0:
    discard pr.lp.fulfilled[idx].fetchAdd(1, moRelaxed)
    idx = (idx-1) shr 1

  discard pr.lp.fulfilled[0].fetchAdd(1, moRelaxed)


# Sanity checks
# ------------------------------------------------------------------------------
# TODO: multithreaded test case

when isMainModule:
  echo "Testing Loop Promises (Producer)"

  var pool: TLPoolAllocator
  pool.initialize()

  block:
    var plp: ProducersLoopPromises
    plp.initialize(pool, 0, 10, 1)
    doAssert plp.getBucket(0) == 0


  block: # Fulfilling all promises
    var prodLoopPromises: ProducersLoopPromises
    prodLoopPromises.initialize(pool, 0, 10000, 1)
    for i in 0'i32 ..< 10000:
      prodLoopPromises.ready(i)
    doAssert prodLoopPromises.lp.fulfilled[0].load(moRelaxed) == 10000
