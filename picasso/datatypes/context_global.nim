# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../channels/channels_mpsc_bounded_lock,
  ../channels/channels_spsc_single_ptr,
  ../memory/persistacks,
  ../config,
  ../primitives/barriers,
  ./sync_types

# Global / inter-thread communication channels
# ----------------------------------------------------------------------------------

# TODO: used to debug a recurrent deadlock on trySend with 5 workers
import ../channels/channels_legacy

type
  ComChannels* = object
    ## Communication channels
    ## This is a global objects and so must be stored
    ## at a global place.
    # - Nim seq uses thread-local heaps
    #   and are not recommended.
    # - ptr UncheckedArray would work and would
    #   be useful if Channels are packed in the same
    #   heap (with padding to avoid cache conflicts)
    # - A global unitialized array
    #   so they are stored on the BSS segment
    #   (no storage used just size + fixed memory offset)
    #   would work but then it requires a pointer indirection
    #   per channel
    #   and a known max number of workers
    thefts*: ptr UncheckedArray[ChannelLegacy[StealRequest]]
    tasks*: ptr UncheckedArray[Persistack[PI_MaxConcurrentStealPerWorker, ChannelSpscSinglePtr[Task]]]

  GlobalContext* = object
    com*: ComChannels
    threadpool*: ptr UncheckedArray[Thread[WorkerID]]
    numWorkers*: int32
    barrier*: PthreadBarrier # TODO windows support

    # TODO track workers per socket / NUMA domain
