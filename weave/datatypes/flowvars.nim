# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../channels/[channels_spsc_single_ptr, channels_spsc_single_object],
  ../memory/allocs,
  ../instrumentation/contracts,
  ../contexts, ../config

# TODO for the Flowvar we need critically need a caching scheme for the channels
# we use the legacy channels in the mean time
import ../channels/channels_legacy

type
  LazyChannel {.union.} = object
    chan*: ChannelRaw
    buf*: array[sizeof(ChannelRaw), byte]

  LazyFlowvar* = ptr LazyFlowvarObj
  LazyFlowvarObj = object
    lazyChan*: LazyChannel
    hasChannel*: bool
    isReady*: bool

  Flowvar*[T] = object
    ## A Flowvar is a simple channel
    # Flowvar are optimized when containing a ptr type.
    # They take less size in memory by testing isNil
    # instead of having an extra atomic bool
    # They also use type-erasure to avoid having duplicate code
    # due to generic monomorphization.

    # when T is ptr:
    #   chan: ptr ChannelSpscSinglePtr[T]
    # else:
    #   chan: ptr ChannelSpscSingleObject[T]
    when not defined(PI_LazyFlowvar):
      chan: ChannelLegacy[T]
    else:
      lazyFV: LazyFlowvar

EagerFV:
  proc newFlowVar*(T: typedesc): Flowvar[T] {.inline.} =
    # result.chan = pi_allocPtr(result.chan.typeof)
    result.chan.initialize(int32 sizeof(T))

  proc setWith*[T](fv: Flowvar[T], childResult: T) {.inline.} =
    ## Send the Flowvar result from the child thread processing the task
    ## to it's parent thread.
    discard fv.chan.trySend(childResult)

  proc forwardTo*[T](fv: Flowvar[T], parentResult: var T) {.inline.} =
    ## From the parent thread awaiting on the result, force its computation
    ## by eagerly processing only the child tasks spawned by the awaited task
    fv.forceFuture(parentResult)
    fv.chan.channel_free() # This caches the channel

LazyFV:
  # Templates everywhere as we use alloca
  template newFlowVar*(T: typedesc): Flowvar[T] =
    var fv = cast[Flowvar[T]](alloca(LazyFlowvarObj))
    fv.lazyFV.lazyChan.chan = nil
    fv.lazyFV.hasChannel = false
    fv.lazyFv.isReady = false
    fv

  template setWith*[T](fv: Flowvar[T], childResult: T) =
    if not fv.lazyFV.hasChannel:
      # TODO: What if sizeof(res) > buffer.
      #       The buffer is only the size of a pointer
      ascertain: sizeof(childResult) <= sizeof(fv.lazyFV.lazyChan.buf)
      copyMem(fv.lazyFV.lazyChan.buf.addr, childResult.unsafeAddr, sizeof(childResult))
      fv.lazyFv.isReady = true
    else:
      ascertain: not fv.lazyFV.lazyChan.chan.isNil
      discard fv.lazyFV.lazyChan.chan.trySend(childResult)

  template forwardTo*[T](fv: Flowvar[T], parentResult: var T) =
    fv.forceFuture(parentResult)
    # No need if its stack alloc
    # otherwise dealt with in forceFuture

  proc allocChannel*(lfv: var LazyFlowvar) =
    preCondition: not lfv.hasChannel
    lfv.hasChannel = true
    lfv.lazyChan.chan = channel_alloc(int32 sizeof(lfv.lazyChan), 0, Spsc)

  proc delete*(chan: ChannelRaw) =
    channel_free(chan)
