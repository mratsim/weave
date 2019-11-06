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
  ./steal_requests

# Global / inter-thread communication channels
# ----------------------------------------------------------------------------------

type
  ComChannels* = object
    ## Communication channels
    ## This is a global objects and so must be stored
    ## at a global place.
    # - Nim seq uses thread-local heaps
    #   and are not recommended.
    # - ptr UncheckedArray would work
    #   however there is pointer indirection so cache misses
    #   and they may be scattered on the heap so locality issue.
    # - the best is to have them as global unitialized array
    #   so they are stored on the BSS segmend
    #   (no storage used just size + fixed memory offset)
    #   however this requires a known max number of workers
    stealRequests: array[PicassoMaxWorkers, ptr ChannelMpscBounded[StealRequest]]
