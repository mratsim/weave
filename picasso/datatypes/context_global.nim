# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../channels/channels_mpsc_bounded_lock,
  ../channels/channels_spsc_single,
  ../memory/object_pools,
  ../static_config,
  ./sync_types

# Global / inter-thread communication channels
# ----------------------------------------------------------------------------------

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
    thievingChannels*: ptr UncheckedArray[ChannelMpscBounded[StealRequest]]
    tasksChannels*: ptr UncheckedArray[array[PicassoMaxSteal, ChannelSpscSingle[Task]]]

  GlobalContext* = object
    com*: ComChannels
    numWorkers*: int32
      # TODO track workers per socket
