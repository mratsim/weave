# Memory optimizations research

## Introduction

On most modern hardware, the number #1 limitation to scalability is memory:
  - Assuming a 3 Ghz CPU, an addition costs 1/3e-9 s = 0.33 ns
  - Accessing one of the operand from main memory would cost 100 ns
    so 300x more
  - Interacting with disks, GPU or between 2 processors on different sockets (NUMA architectures) is hundred times more costly.

See [Latency Numbers every Programmers should know](https://gist.github.com/jboner/2841832)

```
Latency Comparison Numbers (~2012)
----------------------------------
L1 cache reference                           0.5 ns
Branch mispredict                            5   ns
L2 cache reference                           7   ns                      14x L1 cache
Mutex lock/unlock                           25   ns
Main memory reference                      100   ns                      20x L2 cache, 200x L1 cache
Compress 1K bytes with Zippy             3,000   ns        3 us
Send 1K bytes over 1 Gbps network       10,000   ns       10 us
Read 4K randomly from SSD*             150,000   ns      150 us          ~1GB/sec SSD
Read 1 MB sequentially from memory     250,000   ns      250 us
Round trip within same datacenter      500,000   ns      500 us
Read 1 MB sequentially from SSD*     1,000,000   ns    1,000 us    1 ms  ~1GB/sec SSD, 4X memory
Disk seek                           10,000,000   ns   10,000 us   10 ms  20x datacenter roundtrip
Read 1 MB sequentially from disk    20,000,000   ns   20,000 us   20 ms  80x memory, 20X SSD
Send packet CA->Netherlands->CA    150,000,000   ns  150,000 us  150 ms

Notes
-----
1 ns = 10^-9 seconds
1 us = 10^-6 seconds = 1,000 ns
1 ms = 10^-3 seconds = 1,000 us = 1,000,000 ns

Credit
------
By Jeff Dean:               http://research.google.com/people/jeff/
Originally by Peter Norvig: http://norvig.com/21-days.html#answers

Contributions
-------------
'Humanized' comparison:  https://gist.github.com/hellerbarde/2843375
Visual comparison chart: http://i.imgur.com/k0t1e.png
```

Consequently, it is crucial to optimize memory access patterns to avoid
going to main memory as much as possible.
Furthermore system allocators or langage Garbage Collectors are optimized for the general case,
while libraries allocator can be fine-tuned for a very specific case and prevent overhead, cache misses, memory fragmentation.

## Picasso memory usage and access patterns

Unfortunately, a multithreading runtime needs to allocate everything that is shared between threads on the heap including synchronization data structures, tasks, load-balancing utilities like a thread-safe random number generator.

A careful analysis of the lifetime and usage of those heap allocated structures will help design mechanism to minimize memory overhead.

One of the difficulties is thread-safety, some structures might be allocated in one thread, sent to another and destroyed there.

### Synchronization primitives

#### Tasks

Tasks package the work shared between threads.
They are 192 bytes data structure with 96 bytes of metadata and 96 bytes for the
user environment necessary to carry the task.

They contain intrusive next and prev pointers for use with the work stealing deque. Those intrusive pointers can be re-used for a caching mechanism.

Usage:
  - Used between thread via a SPSC channel
  - Used within a thread in a deque (load-balancing)
  - Can be created within any thread
  - Unbounded (user dependent)

Contrary to traditional shared memory work-stealing runtime, there is no hard
requirement for tasks to be heap-allocated. Indeed, in shared memory runtime
the workstealing deque needs to atomically transfer ownership of the task.
In our case we can transfer ownership via pointer or deepcopy + destroy.

Here are the tradeoffs:
- Ownership via pointer tasks:
  - very low-overhead of push/pop/steal in the workstealing deque
  - very low-overhead in the inter-thread channel
  - cactus stack
  - tasks can be destroyed in a thread that did not create them
    requiring threadsafe memory management
    memory fragmentation
- Thread-local tasks:
  - no memory management needed
    in particular tasks are destroyed in the thread that created them
  - lots of 192 bytes memcpy (3 cache lines):
    - to and from the task channels
    - to and from the task deque

#### Steal requests

Steal requests are used for load balancing via work stealing, work sharing and termination detection.

Unlike tasks the number of steal requests is bounded at MaxSteal (usually one) per thread.
Unlike tasks there is no data structure that heavily uses steal requests, they are plain messages between threads.
Unlike tasks they fit in a single cache-line.
Like tasks they also offer a tradeoff between communicating by transfering
the ownership of a pointer or deepcopy + destroy.

Note that steal requests are communicated via a MPSC channel.
Using pointers would allow using a lock-free MPSC channel implementation

Tradeoffs:
- ownership via pointer to steal requests:
  - very low-overhead in the inter-thread channel
  - can use a lock-free MPSC channel
  - steal requests can be destroyed in a thread that did not create them
- thread-local steal requests:
  - requires locks for the MPSC channel (unless a research paper was missed)
  - no memory management needed
    in particular steal requests are destroyed in the thread that create them
  - 32 bytes memcpy (1 cache line):
    - to and from the steal requests channel

#### RNG for victim selection

Choosing the victim to send a steal request to uses a random number generator.
While each thread could have a thread-local RNG, it should not lead to all threads requesting from the same victim in a small window of time.

2 solutions are possible:
- Thread-local RNG seeded independently from each thread (via a Crypto-Secure PRNG for example)
- Multithreaded RNG: note that this might be a contention bottleneck due to multiple threads competing for a shared RNG state. However those threads are idle threads that try to steal work from a victim so it might only impact latency.

### Thread-local synchronization containers

Workers are organized in a informal binary tree: their parent and children
depends on their thread ID.

The workers keeps track of:
  - the state of its children:
    - Working
    - Idle and stealing work
    - Idle and waiting for parent to share work
  - the last steal request of each child if they fail
    to steal work and wait for the parent to share some.

Usage
  - Completely allocated at thread creation start
  - Completely deallocated at thread deletion

### Channels usage

Channels are used for inter-thread synchronization in Picasso and are a key component of the runtime.
Channels cannot be copied, only moved or used by reference.
The channels have a different implementation depending on the use-case:

#### Channels for stolen tasks

Single-Producer Single-Consumer channels with a capacity of 1.
Stored in a global array of arrays `array[MaxWorkers, array[MaxSteal, Channel[Task]]]`.

Note: this assumes that channels are a ptr object, but we might want a ptr to an unchecked array of channels instead to save on binary size and ensure contiguity.

Each worker can have up to MaxSteal steal requests in-flight at any point in time. Steal requests have a pointer to the worker "mailbox".

Usage:
  - Completely allocated at thread creation start
  - Completely deallocated at thread deletion
  - Owned by the master thread
  - Don't move between threads
  - Overhead proportional to number of threads

Due to its size of 1, the channel buffer can be inline with the channel data structure. Also using OS alloc/dealloc for those channels will have no overhead.
The channels can be allocated in one big contiguous chunk of memory.
In that case, they should have padding so that within the array, fields of 2 consecutive channels do not end up in the same cache-line. Alternatively we can use a `tuple[chan: Channel[Task], pad: array[RequiredPadding: byte]]` structure.

#### Channels for steal requests

Multi-Producer Single-Consumer channels with a dynamic but bounded capacity:
  - "MaxSteal * number_of_workers" for a spawned thread
  - "MaxSteal * number_of_workers * 2" for the master thread
    (TODO: the 2x is/was needed when workers sent their state to a manager
           thread for termination detection but a Djikstra toen-passing algorithm as been replaced by a dedicated tree algorithm by Dinan et al)

They serve as a mailbox for steal requests and are stored in a global array `array[MaxWorkers, Channel[StealRequest]]`.

Note: this assumes that channels are a ptr object, but we might want a ptr to an unchecked array of channels instead to save on binary size and ensure contiguity.

Usage:
  - Completely allocated at thread creation start
  - Completely deallocated at thread deletion
  - Owned by the master thread
  - Don't move between threads
  - Overhead proportional to number of threads

The channel buffer cannot be inlined with the channel data structure.
Using OS alloc/dealloc for those channels should have limited overhead though
memory fragmentation may force the channel buffers to end up in different pages
and incure TLB costs.
The channel data structures can be allocated in one big contiguous chunk of memory.
In that case, they should have padding so that within the array, fields of 2 consecutive channels do not end up in the same cache-line. Alternatively we can use a `tuple[chan: Channel[Task], pad: array[RequiredPadding: byte]]` structure.

Similarly the channel buffers can be allocated in one big contiguous chunk of memory, with 64-bit alignment for the start of each channel buffer.

#### Channels for results (Flowvar / Futures)

Single-Producer Single-Consumer channels with a capacity of 1.
Those are public API.

Usage:
  - Created on-demand, potentially from multiple threads
  - Don't move between threads (but a pointer to them may)
  - Can be nested
  - Lifetime may exceed the scope of the flowvar creating routines:
    - The routine that creates the channel should return immediately
      without the need to wait for future completion
    - pointers to futures is sent in tasks if needed for computation
    - a unique handle (move-only) may be passed to other proc or returned.
  - Overhead dependent on workload and allocation strategy:
    - very very high on naive recursive workloads like tree algorithm and fibonacci
      with short computations.

Futures allocation is critical for efficient multithreading of recursive algorithms based on divide-and-conquer or tree search.
If the main computation is short, the memory allocator overhead and potential will be significant if no mechanism is in-place to avoid requesting the OS allocators too much.

This is also impacted by the cactus stack issue (see last chapter).

An ideal allocator strategy would be alloca as:
  - it uses the fact that the lifetime is equal to the creating scope
  - the OS already deals with cactus stacks by design
  - no heap allocation and memory management overhead

See:
  - Proactive Work-Stealing for Futures
    Singer et al
    https://www.cse.wustl.edu/~angelee/home_page/papers/ws-future.pdf

## The cactus stack

A cactus stack happens when a task (for example fibonacci)
spawns N stacks, which then spawns M tasks.
Then the stacks of grandchildren are:
  - Root 1 -> 11 -> 111
  - Root 1 -> 11 -> 112
  - Root 1 -> 12 -> 121
  - Root 1 -> 12 -> 122
and pop-ing from those stacks doesn't translate to a linear memory pop
See:
  - A Practical Solution to the Cactus Stack Problem
    http://chaoran.me/assets/pdf/ws-spaa16.pdf
  - Fibril work-stealing scheduler
    https://github.com/chaoran/fibril
  - Staccato work-stealing scheduler
    https://github.com/rkuchumov/staccato
  - Proactive Work-Stealing for Futures
    Singer et al
    https://www.cse.wustl.edu/~angelee/home_page/papers/ws-future.pdf
