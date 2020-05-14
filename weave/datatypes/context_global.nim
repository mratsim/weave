# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../cross_thread_com/channels_mpsc_unbounded_batch,
  ../cross_thread_com/channels_spsc_single_ptr,
  ../memory/[persistacks, memory_pools],
  ../config,
  ../primitives/barriers,
  ./sync_types, ./binary_worker_trees

when WV_Backoff:
  import ../cross_thread_com/event_notifiers

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
    #   per channel and a known max number of workers

    # Theft channels are bounded to "NumWorkers * WV_MaxConcurrentStealPerWorker"
    thefts*: ptr UncheckedArray[ChannelMpscUnboundedBatch[StealRequest]]
    tasksStolen*: ptr UncheckedArray[Persistack[WV_MaxConcurrentStealPerWorker, ChannelSpscSinglePtr[Task]]]
    jobsSubmitted*: ptr UncheckedArray[ChannelMpscUnboundedBatch[Job]]
    when static(WV_Backoff):
      parking*: ptr UncheckedArray[EventNotifier]

  GlobalContext* = object
    com*: ComChannels
    threadpool*: ptr UncheckedArray[Thread[WorkerID]]
    numWorkers*: int32
    mempools*: ptr UncheckedArray[TlPoolAllocator]
    barrier*: SyncBarrier
      ## Barrier for initialization and deinitialization
    jobNotifier*: ptr EventNotifier
      ## When Weave works as a dedicated execution engine
      ## we need to park it when there is no CPU tasks.

    # TODO track workers per socket / NUMA domain
