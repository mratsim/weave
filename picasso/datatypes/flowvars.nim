# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import ../channels/channels_spsc_single_ptr

type Flowvar*[T] = ptr ChannelSpscSinglePtr[T]
  ## A Flowvar is a simple channel

template newFlowVar*(T: typedesc): Flowvar[T] =
  result = createSharedU(ChannelSpscSinglePtr[T])
  initialize(result)

template setWith*[T](fv: Flowvar[T], childResult: T) =
  ## Send the Flowvar result from the child thread processing the task
  ## to it's parent thread.
  discard fv[].trySend(childResult)

template forwardTo*[T](fv: Flowvar[T], parentResult: var T) =
  ## From the parent thread awaiting on the result, force its computation
  ## by eagerly processing only the child tasks spawned by the awaited task
  fv.forceFuture(parentResult)
  freeShared(fv)
