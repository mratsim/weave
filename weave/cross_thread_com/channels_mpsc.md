# Shared memory MPSC channel research
Note: Channels are queues

## Usage in the project

Channels are used for the following types:

- Task:
  - ptr objects
  - SPSC channels
  - buffered - 1 item
- Futures
  - ptr objects
  - SPSC channels
  - buffered - 1 item
- StealRequest
  - object of size 32 bytes or pointers to heap allocated steal requests
  - MPSC channels
  - buffered - "MaxSteal * num_workers" or "2 * MaxSteal * num_workers" (Main thread)
- Memory Pool (pointer to memory blocks)
  - pointer objects
  - MPSC channels
  - The memory pool uses extreme freelist sharding. Eache arena has it's own
    remote freelist for remote threads, instead of having just one per thread:
    Each queue is bounded to (ArenaSize - MetadataSize) / Memory Block size

## Notes on StealRequest

Initially StealRequests were fully copied (32 bytes) into a lock-based channel. Changing to just passing pointers significantly improved performance even with a lock-based channel. This opened up the opportunity to use list-based channel designs.

As the producers have nothing to do anyway, a lock-based solution only on the producer side also work. Furthermore each producer is only allowed a limited number of steal requests, assigned randomly, so potential contention is very low even for lock-based solution.

## History and requirement notes

There are a lot of litterature regarding linked-list based MPSC channels.

### v0

https://github.com/mratsim/weave/blob/083300965984283a860623caeae6448c6ab3158b/weave/channels/channels_mpsc_bounded_lock.nim

The first MPSC channels were lock-based (but high performance) bounded channels

### v0.5

https://github.com/mratsim/weave/blob/630f2d908b8cd1f4e4a8fb0871fbec95389ab093/weave/channels/channels_mpsc_unbounded.nim

Then for the memory-pool I tried to use lock-free MPSC channel similar to those used in [Snmalloc](https://github.com/microsoft/snmalloc) a message-passing based memory allocator from Microsoft.

The queue is heavily inspired by Pony language's actor message queue.

Unfortunately both Snmalloc/Pony implementations have the following issues, they:
- Hold on the last item of the queue: unsuitable for steal requests
- Require memory management of a stub node and/or the node.
- For snmalloc it seems like the stub node can be returned from the queue (it's an unnamed memory block so it is "fungible")
- They never update the "back" pointer of the queue when dequeueing so the back pointer
  still points to an unowned item, requiring the caller to do an emptiness check
- There is no way of estimating the number of enqueued items for the consumers which is necessary for both
  steal requests (adaptative stealing) and memory pool (estimating free memory blocks)

### v1

https://github.com/mratsim/weave/blob/b796d1a0efb15cad68e2b06ddaa305b08cf5f722/weave/channels/channels_mpsc_unbounded.nim

So the channel has been modified with Dmitry Vyukov intrusive design + an additional count variable.

### v2

https://github.com/mratsim/weave/blob/a8f42d302e3d68f397374e9b14e964f647cb9afa/weave/channels/channels_mpsc_unbounded_batch.nim

Also while trying to fit the queue for memory management
a new need for batching arised. Snmalloc paper mentionned that batching contributed significantly to performance. Each thread-local arena also manages a temporal radix tree to pass back memory blocks that were not they own.
  Remote threads are grouped by buckets and once a threshold is reached, Snmalloc batches all memory blocks and send them to the author of the bucket, circulating memory blocks to threads that potentially did not own them with "receiver miss" being bounded to 7 (depending on address space and radix tree parameters).

Weave instead chooses to directly send messages to the final consumer and do batching on the consumer side.

However this required a new queue design as the original queues only supported batching for the consumers and it was very error-prone and potentially to add consumer batching to Vyukov's intrusive queue as a dummy node was reenqueued regularly and had to be tested for and skipped when batching.

So the queue has been retired from the codebase for an another MPSC intrusive lockless queue with batching support for both the producers and the consumer.
The dummy node is instead fixed in the front of the queue.
In naive testing, consumer batching can improve performance by 50%.

### v3

The v2 channel main issue is the need for a spinlock after a failed compare-and-swap of the consumer. This compare-and-swap is costly but the spinlock is worse as in case of high producer contention, the consumer
  might be deprioritized due to the `cpuRelax()`.

With Weave now featuring being an beackground executor service, this is problematic when interfacing with foreign threads if several of them
keep hammering the queue with jobs.

## References

- Snmalloc MPSC queue
  https://github.com/microsoft/snmalloc/blob/master/snmalloc.pdf (page 4)
  https://github.com/microsoft/snmalloc/blob/7faefbbb0ed69554d0e19bfe901ec5b28e046a82/src/ds/mpscq.h#L29-L83
- Pony-lang queue
  https://qconlondon.com/london-2016/system/files/presentation-slides/sylvanclebsch.pdf
  https://github.com/ponylang/ponyc/blob/7145c2a84b68ae5b307f0756eee67c222aa02fda/src/libponyrt/actor/messageq.c
- Dmitry Vyukov intrusive node-based MPSC queue
  http://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue

Implementation details are here: https://github.com/mratsim/weave/pull/21

## A note on non-intrusive approaches

A non-intrusive approach would require some memory reclamation of the node which we don't want when implementing
a memory pool. The extra pointer indirection is probably also costly in terms of cache misses while the
"next" field will be in the same cache-line as fresh data for the producers or required data for the consumer.
