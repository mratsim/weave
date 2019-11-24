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
  - unbuffered (rendezvous / blocking)
- StealRequest
  - object of size 32 bytes or pointers to heap allocated steal requests
  - MPSC channels
  - buffered - "MaxSteal * num_workers" or "2 * MaxSteal * num_workers" (Main thread)
- Memory Pool (pointer to memory blocks)
  - pointer objects
  - MPSC channel
  - unbounded

## Requirements notes

There are a lot of litterature regarding linked-list based MPSC channels.

Initially the MPSC channels were implemented following Microsoft's message-passing allocator [Snmalloc](https://github.com/microsoft/snmalloc) implementation which is itself heavily inspired by Pony language's actor message queue.

However they:

- Hold on the last item of the queue: unsuitable for steal requests
- Require memory management of a stub node: snmalloc overwrites it and never seem to reclaim its memory
- They never update the "back" pointer of the queue when dequeueing so the back pointer
  still points to an unowned item, requiring the caller to do an emptiness check
- There is no way of estimating the number of enqueued items for the consumers which is necessary for both
  steal requests (adaptative stealing) and memory pool (estimating free memory blocks)

So the unbounded queue has been heavily modified with inspiration from the intrusive Vyukov queue at:
- http://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue

An alternative implementation using CAS is discussed here:
- https://groups.google.com/forum/#!topic/comp.programming.threads/M_ecdRRlgvM

It may be possible to use the required "count" atomic field for further optimization as other queues don't need it
but the likelihood is low given that it's a contended variable by all threads accessign the data-structure
compared to "next" field.

A non-intrusive approach would require some memory reclamation of the node which we don't want when implementing
a memory pool. The extra pointer indirection is probably also costly in terms of cache miss while the
"next" field will be in the same cache-line as fresh data for the producers or required data for the consumer.
- http://www.1024cores.net/home/lock-free-algorithms/queues/non-intrusive-mpsc-node-based-queue (non-intrusive)
- Reviews:
  - https://int08h.com/post/ode-to-a-vyukov-queue/
  - http://concurrencyfreaks.blogspot.com/2014/04/multi-producer-single-consumer-queue.html
  - http://psy-lob-saw.blogspot.com/2015/04/porting-dvyukov-mpsc.html

Lastly something more complex but with wait-free and linearizability guarantees like
the MultiList queue: https://github.com/pramalhe/ConcurrencyFreaks/blob/master/papers/multilist-2017.pdf probably has more latency and/or less throughput.

Note that for steal requests as pointers we can actually guarantee that the thread that allocated them
can destroy/recycle them when no other thread is reading them, making list-based MPSC channels suitable.
Moving a pointer instead of 32 byte object resulted in a significant overhead reduction (25%) in https://github.com/mratsim/weave/pull/13.

## More notes

Arguably there might be cache thrashing between the producers when writing the tail index and the data. However they don't have any useful work to do. What should be prevented is that they interfere with the consumer.

As the producers have nothing to do anyway, a lock-based solution only on the producer side should be suitable.

Furthermore each producer is only allowed a limited number of steal requests.

Also Dmitry Vyokov presents "Memory Queues": https://groups.google.com/forum/#!topic/comp.programming.threads/4ILh6yY5fV4
to be used with thread-safe memory allocator such as: https://groups.google.com/forum/embed/#!topic/comp.programming.threads/gkX0tIWR_Gk

## References

There is a definite lack of papers on ring-buffer based MPSC queues

- https://github.com/dbittman/waitfree-mpsc-queue
- https://github.com/rmind/ringbuf
- https://github.com/cloudfoundry/go-diodes (can overwrite data)
- Disruptor: https://github.com/LMAX-Exchange/disruptor/wiki/Blogs-And-Articles
  Note that this is a ringbuffer of pointers, it doesn't hold data
