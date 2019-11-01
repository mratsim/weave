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
  - object of size 32 bytes
  - MPSC channels
  - buffered - "MaxSteal * num_workers" or "2 * MaxSteal * num_workers" (Main thread)

## Requirements notes

There are a lot of litterature regarding linked-list based MPSC channels.
Given that we do not need linearizability guarantee, the Vyukhov MPSC queue would probably be enough:
- http://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue (Intrusive)
- http://www.1024cores.net/home/lock-free-algorithms/queues/non-intrusive-mpsc-node-based-queue (non-intrusive)
- Reviews:
  - https://int08h.com/post/ode-to-a-vyukov-queue/
  - http://concurrencyfreaks.blogspot.com/2014/04/multi-producer-single-consumer-queue.html
  - http://psy-lob-saw.blogspot.com/2015/04/porting-dvyukov-mpsc.html

compared to something more complex but with wait-free and linearizability guarantees like
the MultiList queue: https://github.com/pramalhe/ConcurrencyFreaks/blob/master/papers/multilist-2017.pdf which probably has more latency and/or less throughput.

However the MPSC queue will be used for StealRequest. Linked list based queues will require to pass data as a pointer meaning allocation can happen in one thread and deallocation in another.
This requires multithreaded alloc/free scheme. As we probably would want to implement pool allocation to reduce allocator pressure complicating the pool allocator design.

Another issue is that assuming we pool StealRequests, they will trigger access to the same cacheline from random threads so it's probably better if StealRequests were thread-local.

Lastly, in the channel-based work-stealing, the thread that has work to do must also handle the steal requests (contrary to shared-memory design where the threads that have nothing to do handle the stealing). This means that that busy thread will also need to handle heap/pool deallocation.
