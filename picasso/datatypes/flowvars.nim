# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../channels/[channels_spsc_single_ptr, channels_spsc_single_object],
  ../memory/allocs

type Flowvar*[T] = object
  ## A Flowvar is a simple channel
  # Flowvar are optimized when containing a ptr type.
  # They take less size in memory by testing isNil
  # instead of having an extra atomic bool
  # They also use type-erasure to avoid having duplicate code
  # due to generic monomorphization.
  when T is ptr:
    chan: ptr ChannelSpscSinglePtr[T]
  else:
    chan: ptr ChannelSpscSingleObject[T]


proc newFlowVar*(T: typedesc): Flowvar[T] {.inline.} =
  result.chan = pi_allocPtr(result.chan.typeof)
  result.chan[].initialize()

proc setWith*[T](fv: Flowvar[T], childResult: T) {.inline.} =
  ## Send the Flowvar result from the child thread processing the task
  ## to it's parent thread.
  discard fv.chan[].trySend(childResult)

proc forwardTo*[T](fv: Flowvar[T], parentResult: var T) {.inline.} =
  ## From the parent thread awaiting on the result, force its computation
  ## by eagerly processing only the child tasks spawned by the awaited task
  fv.forceFuture(parentResult)
  pi_free(fv.chan)
