# Datatypes

This folder contains data structures to optimize memory allocation,
prevent memory fragmentation and reduce cache misses.

## Descriptions:

### Internal high level description

From https://github.com/mratsim/weave/blob/a8f42d302e3d68f397374e9b14e964f647cb9afa/weave/scheduler.nim#L32

>
> Caching description:
>
> Thread-local objects, with a lifetime equal to the thread lifetime
> are allocated directly with no caching.
>
> Short-lived synchronization objects are allocated depending on their characteristics
>
> - Steal requests:
>   are bounded, exchanged between threads but by design
>   a thread knows when its steal request is unused:
>   - either it received a corresponding task
>   - or the steal request was return
>
>   So caching is done via a ``Persistack``, a simple stack
>   that can either recycle an object or be notified that object is unused.
>   I.e. even after lending an object its reference persists in the stack.
>
> - Task channels:
>   Similarly, everytime a steal request is created
>   a channel to receive the task must be with the exact same lifetime.
>   A persistack is used as well.
>
> - Flowvars / Futures:
>   are unbounded, visible to users.
>   In the usual case the thread that allocated them, collect them,
>   if the flowvar is awaited in the proc that spawned it.
>   A flowvar may be stolen by another thread if it is returned (not tested at the moment).
>   Tree and recursive algorithms might spawn a huge number of flowvars initially.
>
>   Caching is done via a ``thread-safe memory pool``.
>   If WV_LazyFlowvar, they are allocated on the stack until we have
>   to extend their lifetime beyond the task stack.
>
> - Tasks:
>   are unbounded and either exchanged between threads in case of imbalance
>   or stay within their threads.
>   Tree and recursive algorithms might create a huge number of tasks initially.
>
>   Caching is done via a ``look-aside list`` that cooperate with the memory pool
>   to adaptatively store/release tasks to it.
>
> Note that the memory pool for flowvars and tasks is able to release memory back to the OS
> The memory pool provides a deterministic heartbeat, every ~N allocations (N depending on the arena size)
> expensive pool maintenance is done and amortized.
> The lookaside list hooks in into this heartbeat for its own adaptative processing
>
> The mempool is initialized in worker_entry_fn
> as the main thread needs it for the root task

## In-depth description for the memory pool and lookaside buffer
### Scalable memory management and solving the cactus stack problem

From PR https://github.com/mratsim/weave/pull/24

> This PR provides an innovative solution to memory management in a multithreading runtime.
> It's also an alternate approach to the cactus stack problem which has been plaguing runtimes for about 20 years (since Cilk).
> ## History
>
> Notoriously, both Go and Rust had troubles to handle them and used OS primitives instead:
>
>     * https://mail.mozilla.org/pipermail/rust-dev/2013-November/006314.html
>
>     * https://docs.google.com/document/d/1wAaf1rYoM4S4gtnPh0zOlGzWtrZFQ5suE8qr2sD8uWQ/pub
>
>
> Cilk handling of cactus stacks makes Cilk function have a different calling convention and
> unusable from regular C.
>
> And in research:
>
>     * https://pdos.csail.mit.edu/~sbw/papers/pact183a-lee.pdf requires a fork of the Linux kernel
>
>     * http://chaoran.me/assets/pdf/ws-spaa16.pdf uses a techniques similar to fibers which is practical and very fast however requires specific handling of all possible calling convention and register saving/restore combinations from Linux/MacOS/Windows (cdecl, fastcall, stdcall) and CPU Arch (X86, ARM, MIPS, Risc, ...) significantly increasing maintenance burden. Note however that any coroutine library should already provide the related primitives.
>
>
> ## The changes
>
> So this PR introduces 2 keys memory management data structure:
>
>     * a threadsafe memory pool inspired by the latest [Mimalloc](https://github.com/microsoft/mimalloc) and [Snmalloc](https://github.com/microsoft/snmalloc) research.
>
>     * a lookaside buffer to specially handle tasks and scale to several tens of billions of tasks created in a couple of milliseconds.
>
>
> While before this PR, the runtime could handle this load:
>
>     * It did not return cached tasks at all to the OS
>
>     * The size of the channels/futures cache was hardcoded
>
>     * An imbalance due to tasks being produced by one thread (a for-loop for example) and always freed in another would lead to always depleted caches on the producer end and always full caches in the consumer threads, which would be worst case cache utilization.
>
>
> ## How does that work
>
> There is actually one memory pool per thread.
>
> The memory pools service aligned fixed size memory block of 256 bytes for tasks (192 bytes) and flowvars (128 or 256 bytes due to cache line padding of contention fields).
> It is much faster than the system allocator for single-threaded workload and somewhat faster when memory is allocated in a thread and released from another.
>
> The memory pools manage arenas of size 16K bytes, this magic number may need more benchmarks.
>
> > The main issue is the 64K aliasing problem where when accessing from a single core 2 structures having the same address module 64K automatically causes a L1 cache miss. This is even more problematic with Hyperthreading. Solving this requires either putting Arena metadata at random positions or using arenas smaller than 64K bytes in size to diminish the chances of aliasing.
>
> Similar to Mimalloc extreme freelist sharding, freelists are not managed at the thread-local allocator level but at the arena level, each arenas keep track of its own freelists: one for usable free blocks, one for deferred free block, one for blocks freed by remote threads.
>
>     * Freed blocks are not added directly to the usable freelist, they are kept separately, this ensures that the usable freelist is emptied regularly. When it is emptied is a good time to start expensive memory maintenance that should be amortized on many allocations like releasing one or more arenas to the system allocator. This regular expensive maintenance is called the heartbeat and will be important later.
>
>     * The remote free list is implemented as a MPSC channel. Mimalloc does not have proper boundaries for cross-thread synchronization, remote threads and local threads are synchronizing by atomic compare-and-swap loops. Snmalloc does use a MPSC queue for synchronizing but to benefit from batching which is much easier to implement on the producer size, remote allocators are put into buckets of a temporal radix tree and freed blocks are batched send towards the head of those buckets. This requires extra round-trip for a single freed block to attain its ultimate destination and require implementing a temporal radix tree, making allocator implementation and maintenance too complex for my taste. Instead I use a novel MPSC lockless queue that supports batching on the consumer side (and the producer side as it's easy). Messages are send directly to their end destination, minimizing latency.
>
>
> The memory pools act in general like a LIFO allocator as child tasks as resolved before their parent. It's basically a thread-local cactus stack. Unlike TBB, there is no depth-limitation so it maintains the busy-leaves property of work-stealing, it is theoretically unbounded memory growth (unlike work-first / parent-stealing runtimes like Cilk) but unlike previous research we are heap-allocated.
>
> The memory pool is sufficient to deal with futures/flowvars as in general they are awaited/synced in the context that spawned the child, the scheme + specialized SPSC channel for flowvars accounted to 10% overhead reduction compared to the legacy channels with hardcoded cache on eager flowvar Fibonacci(40) (i.e. all channels allocated on the heap as opposed to using alloca when possible).
>
> If we allow future escaping their context (i.e. returning a future), the memory pool should also provide good default performance.
>
> Unfortunately, this didn't work out very well for tasks, both fibonacci(40) spiked from less than 200ms (lazy futures)/400ms (eager futures) to 2s/2.3s compared with just storing tasks in an always growing never-releasing stack. Why? Because it was stressing the memory pool with the "slow" multithreaded path due to the tasks being so small that they were regularly stolen and released in other thread.
>
> So a new solution was devised: the lookaside buffers / lookaside lists.
> They extend the original intrusive stack by supporting task eviction, this helps 2 use-case:
>
>     * long-running processes with some spike in tasks, but that need the memory elsewhere otherwise
>
>     * producer-consumer scenario to avoid one side with depleted caches and another with unbounded cache growth
>
>
> Now the main question is when to do task eviction? We want to amortize cost and we want an adaptative solution to the recent workload. Also the less metadata/counters we need to increment/decrement on the fast path the better as recursive workload like tree search may spawn billions of tasks at once which may means billions of increment.
> For task eviction, the lookaside buffer hooks into the memory pool heartbeat, when it is time to do amortized expensive memory maintenance, the memory pool has a callback field that triggers also task eviction in the lookaside buffer depending on the current buffer size and the recent requests.
> Not that it is important for the heartbeat to be triggered on memory allocations as task evictions deallocate and would otherwise lead to an avalanche effect.
> ## How does it perform
>
> Very well on the speed side, actually the only change that had a noticeable impact (7%) on performance was properly zero-ing the task data structure.
> Further comparisons against the original implementation for long-running producer-consumer workload is needed on both CPU and memory consumption front.
> ## What's next?
>
>     * The `recycle` that allows freeing a memory block to the memory pool requires a threadID argument.
>       This could use pthread_self or assembly or windows API to get a thread ID instead as this requirements leaks into the rest of the codebase.
>
>     * The memory pool can be tuned some more, like adding a "full arenas" list to avoid scanning them repeatedly. This however makes remote frees more complex as remote threads now needs to notify that the page isn't full anymore.
>       Given the current already very good performance and low-overhead of the memory subsytem, it's of lower priority.
