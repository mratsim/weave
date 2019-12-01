# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../channels/[channels_spsc_single_ptr, channels_spsc_single_object, channels_lazy_flowvars],
  ../memory/[allocs, memory_pools],
  ../instrumentation/contracts,
  ../config, ../contexts

type
  LazyChannel* {.union.} = object
    chan*: ptr ChannelLazyFlowvar
    buf*: array[sizeof(pointer), byte] # for now only support pointers

  LazyFlowVar* = object
    # No generics allowed at the moment
    # has converting stack lazy futures to heap is done
    # deep in the runtime with no access to type information.
    hasChannel*: bool
    isReady*: bool
    lazy*: LazyChannel

  Flowvar*[T] = object
    ## A Flowvar is a simple channel
    # Flowvar are optimized when containing a ptr type.
    # They take less size in memory by testing isNil
    # instead of having an extra atomic bool
    # They also use type-erasure to avoid having duplicate code
    # due to generic monomorphization.
    #
    # A lazy flowvar has optimization to allocate on the heap only when required

    when defined(WV_LazyFlowvar):
      lfv: ptr LazyFlowVar # alloca allocated
    elif T is ptr:
      chan: ptr ChannelSpscSinglePtr[T]
    else:
      chan: ptr ChannelSpscSingleObject[T]

func isSpawned*(fv: Flowvar): bool {.inline.}=
  ## Returns true if a future is spawned
  ## This may be useful for recursive algorithms that
  ## may or may not spawn a future depending on a condition.
  ## This is similar to Option or Maybe types
  when defined(WV_LazyFlowvar):
    return not fv.lfv.isNil
  else:
    return not fv.chan.isNil

EagerFV:
  proc newFlowVar*(pool: var TLPoolAllocator, T: typedesc): Flowvar[T] {.inline.} =
    result.chan = pool.borrow(typeof result.chan[])
    result.chan[].initialize()

  proc readyWith*[T](fv: Flowvar[T], childResult: T) {.inline.} =
    ## Send the Flowvar result from the child thread processing the task
    ## to its parent thread.
    let resultSent = fv.chan[].trySend(childResult)
    postCondition: resultSent

  proc forceComplete*[T](fv: Flowvar[T], parentResult: var T) {.inline.} =
    ## From the parent thread awaiting on the result, force its computation
    ## by eagerly processing only the child tasks spawned by the awaited task
    fv.forceFuture(parentResult)
    recycle(myID(), fv.chan)

LazyFV:
  # Templates everywhere as we use alloca
  template newFlowVar*(pool: TLPoolAllocator, T: typedesc): Flowvar[T] =
    var fv = cast[Flowvar[T]](alloca(LazyFlowVar))
    fv.lfv.lazy.chan = nil
    fv.lfv.hasChannel = false
    fv.lfv.isReady = false
    fv

  template readyWith*[T](fv: Flowvar[T], childResult: T) =
    if not fv.lfv.hasChannel:
      # TODO: buffer the size of T
      static: doAssert sizeof(childResult) <= sizeof(fv.lfv.lazy.buf)
      copyMem(fv.lfv.lazy.buf.addr, childResult.unsafeAddr, sizeof(childResult))
      fv.lfv.isReady = true
    else:
      ascertain: not fv.lfv.lazy.chan.isNil
      discard fv.lfv.lazy.chan[].trySend(childResult)

  template forceComplete*[T](fv: Flowvar[T], parentResult: var T) =
    fv.forceFuture(parentResult)
    # Reclaim memory
    if not fv.lfv.hasChannel:
      ascertain: fv.lfv.isReady
      copyMem(parentResult.addr, fv.lfv.lazy.buf.addr, sizeof(parentResult))
    else:
      ascertain: not fv.lfv.lazy.chan.isNil
      recycle(myID(), fv.lfv.lazy.chan)

# TODO destructors for automatic management
#      of the user-visible flowvars
