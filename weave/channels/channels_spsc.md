# Shared memory SPSC channel research

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

## Bounded channel optimization notes

### Context

One of the most expensive hardware operation is the modulo.

According to the [instruction tables by Agner Fog](https://www.agner.org/optimize/instruction_tables.pdf), they take 14 to 45 cycles on Ryzen and 11 to 57 cycles on Skylake-X.

By comparison, addition, multiplication and shifts take only one-cycle.

As the channel bounds are known at compile-time the compiler will replace them with bit tricks that might take 1 cycle (if power of 2) to 5 cycles. However sometimes it might not due that for hard to debug reasons like not being able to check that the input is always positive.

Bounded queues / channels are often written like a ring-buffer
with a head and a tail fields
and enqueue / dequeue operations being done at the index corresponding to head/tail modulo the queue capacity.

Furthermore if testing naively for a full queue is:
  `tail mod Capacity == 0`
and testing naively for an empty queue is:
  `head mod Capacity == 0)`
but when the queue is empty:
  `head mod Capacity == tail mod Capacity == 0`
so often the real capacity is Capacity+1 and this is
what is used to allow empty/full disambiguation.

### The problems

So we want to solve 2 problems:
  - the cost of modulo
  - the extra unused element overhead, which creates
    off-by-one error opportunity and is bloat on small queues.
    For Picasso each worker has a channel of size 1 per other existing worker

### Example naive implementation

_Note: this is a single threaded implementation,
       for multithreading, atomics or locks + padding to
       avoid false sharing should be added_

[Example](https://github.com/mratsim/weave/blob/04b750d884644df04d07b244e9672863516bb04e/e04_channel_based_work_stealing/bounded_queue.nim#L3-L42):

```Nim
type
  BoundedQueue*[N: static int, T] = object
    head, tail: int
    buffer: ptr array[N+1, T] # One extra to distinguish between full and empty queues

proc bounded_queue_alloc*(
       T: typedesc,
       capacity: static int
      ): BoundedQueue[capacity, T] {.inline.}=
  result.buffer = cast[ptr array[capacity+1, T]](
    # One extra entry to distinguish full and empty queues
    malloc(T, capacity + 1)
  )
  if result.buffer.isNil:
    raise newException(OutOfMemError, "bounded_queue_alloc failed")

func bounded_queue_free*[N, T](queue: sink BoundedQueue[N, T]) {.inline.}=
  free(queue.buffer)

func bounded_queue_empty*(queue: BoundedQueue): bool {.inline.} =
  queue.head == queue.tail

func bounded_queue_full(queue: BoundedQueue): bool {.inline.} =
  (queue.tail + 1) mod (queue.N+1) == queue.head

func bounded_queue_enqueue*[N,T](queue: var BoundedQueue[N,T], elem: sink T){.inline.} =
  assert not queue.bounded_queue_full()

  queue.buffer[queue.tail] = elem
  queue.tail = (queue.tail + 1) mod (N+1)

func bounded_queue_dequeue*[N,T](queue: var BoundedQueue[N,T]): owned T {.inline.} =
  assert not queue.bounded_queue_empty()

  result = queue.buffer[queue.head]
  queue.head = (queue.head + 1) mod (N+1)

func bounded_queue_head*[N,T](queue: BoundedQueue[N,T]): lent T {.inline.} =
  assert not queue.bounded_queue_empty()
  queue.buffer[queue.head]
```

### Litterature

#### On the extra element

The following blog post goes over a way to solve that for ring buffers:
- https://www.snellman.net/blog/archive/2016-12-13-ring-buffers/

And this blog post applies that queues and interestingly allows
head to be in the range [0, 2\*size) and tail [2\*size, 4\*size:
- http://www.vitorian.com/x1/archives/370

A similar technique in the chip design paper in page 3:
- http://www.sunburst-design.com/papers/CummingsSNUG2002SJ_FIFO1.pdf

In summary those 2 techniques use extra bit(s) on the head and tail index to save on extra logic to disambiguate empty and full.

They require size to be a power of 2 however for efficient rollover via a right shift instead of modulo probably would use more space than just using an extra empty-slot.

#### On the modulo

We can use a substraction `if tail >= Capacity: tail -= Capacity`, can be well predicted by the hardware. The difference
with shifting is negligeable.

The compiler would probably convert it to a conditional mov on x86

or more explicitly:
```Nim
chan.tail += if chan.tail + 1 >= Capacity: 1 - Capacity
             else: 1
```

Or with bit twiddling
```Nim
x -= N and -int(x >= N)
``\

Or we can even use weird ASM tricks
```asm
                  ; precondition: 0 <= x <= N
                  ; (N is constant)
    mov y, 0      ; set up mask
    cmp x, N-1    ; set carry flag if x >= N
    sbb y, 0      ; subtract 1 from y if carry flag set
    and x, y      ; set x to zero if x == N
```

### Advanced performance issues

#### False sharing

Even once the previous modulo/size issues, a naive design of the queue will be subject to cache thrashing due to false sharing.

Padding by a single cache line might not be enough due to prefetching.

Every send/recv operations will need to access contested cache-line to read or write the head and tail indices. In the litterature (see MCRingBUffer paper or B-Queue paper) one way around that is to cache on the producer/consumer cache-line a valid index up to which no isEmpty/isFull check is required.

Designers of the queue then have tradeoffs:
  - regarding the distance between the head and tail, to always keep a cache-line in-between them
  - regarding batching to limit reading from the read/write index in the other thread cacheline
    - which requires unused memory slots
    - is only useful if a batch is bigger than a cacheline
    - might deadlock in a case of MCRingBuffer (see B-Queue paper http://psy-lob-saw.blogspot.com/2013/11/spsc-iv-look-at-bqueue.html blog on B-Queue)
    - Latency to fight the empty queue cache thrashing with thee temporal slipping technique
  - regarding a queue optimized for always near-full scenarios or always near empty (Liberty Queue paper)
  - regarding using data null/not-null values to check for fullness/emptiness

### Queues of pointer objects

#### Performance

If a queue is only used for pointer objects or options testing if a queue is empty
or full only requires testing the relevant read or write index and checking if the data is nil.
This avoids accessing both indexes for each enqueue/deque leading to contention between the reader and the writer.

#### Code size

Operations on queues of pointer objects can be typed-erase to avoid duplicate code.
This is important for channels of futures as they may be used
in complex codebases with lots of
different types with Futures/Flowvar encapsulating them.

## SPSC Queue formal verification:
- Correct and Efficient Bounded FIFO Queues, Nhat Minh Le et al:

  https://www.irif.fr/~guatto/papers/sbac13.pdf

  SPSC Queue for weak memory model with formal proof.
  It also supports batch enqueue/deque

- Critical Sections and Producer Consumer Queues in Weak Memory Systems

  Higham & Kawash

  https://prism.ucalgary.ca/bitstream/handle/1880/46030/1997-604-06.pdf

## Implementations and write-up

- @Deaod extensive SPSC queue benchmarks:

  https://github.com/Deaod/RingBufferBenchmark

- Dmitry Vyukov review of [FastFlow](http://calvados.di.unipi.it/) SPSC queue:

  http://www.1024cores.net/home/lock-free-algorithms/queues/fastflow

- SPSC Queues in Java, with steps by steps optimizations

  http://psy-lob-saw.blogspot.com/p/lock-free-queues.html

- B-Queue, Efficient and Practical Queuing for FastCore-to-Core Communication

  Junchang Wang, Kai Zhang, Xinan Tang, Bei Hua

  http://staff.ustc.edu.cn/~bhua/publications/IJPP_draft.pdf

- Liberty Queues for EPIC architecture

  Jablin et al

  https://pdfs.semanticscholar.org/0e6d/a0e2d7b4e45764dc2e8a3a8d1ae903fd70cd.pdf

- A Lock-Free, Cache-Efficient Shared Ring Buffer for Multi-Core Architectures

  Patrick P. C. Lee, Tian Bu, Girish Chandranmenon

  http://www.cse.cuhk.edu.hk/~pclee/www/pubs/ancs09poster.pdf

- The Lynx Queue

  http://www-dyn.cl.cam.ac.uk/~tmj32/wordpress/the-lynx-queue/

- C++ SPSC queues with in-depth dive into memory models

  https://kjellkod.wordpress.com/2012/11/28/c-debt-paid-in-full-wait-free-lock-free-queue/

- Producer-Consumer Queues (minimal modification of Lamport for significant perf increase on shared-memory system)

  https://pdfs.semanticscholar.org/1b0c/2563aecc2062298cd71850bdece32caeed6d.pdf

- FastForward Queues (minimal modification of Lamport for significant perf increase on shared-memory system)

  _requires elements to be nullable (i.e. pointers or Options) for isEmpty or isFull to not use head+tail at the same time and touch 2 cache lines._

  https://www2.cs.fau.de/teaching/WS2014/ParAlg/slides/insecure/material/queue-concurrent_lock-free.pdf

- The Computer Science of Concurrency, the early years

  Leslie Lamport

  https://lamport.azurewebsites.net/pubs/turing.pdf
