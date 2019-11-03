# The cactus stack

A cactus stack happens when a task (for example fibonacci)
spawns N stacks, which then spawns M tasks.
Then the stacks of grandchildren are:
  - Root 1 -> 11 -> 111
  - Root 1 -> 11 -> 112
  - Root 1 -> 12 -> 121
  - Root 1 -> 12 -> 122
and pop-ing from those stacks doesn't translate to a linear memory pop

This is also called a [parent-pointer-tree](https://en.wikipedia.org/wiki/Parent_pointer_tree)


## Litterature

- A Practical Solution to the Cactus Stack Problem
  Chaoran Yang, John Mellor-Crummey
  http://chaoran.me/assets/pdf/ws-spaa16.pdf
- Using Memory Mapping to Support Cactus Stacks
  in Work-Stealing Runtime Systems
  I-Ting Angelina Lee, Silas Boyd-Wickizer, Zhiyi Huang, Charles E. Leiserson
  https://pdos.csail.mit.edu/~sbw/papers/pact183a-lee.pdf
- Proactive Work-Stealing for Futures
  Kyle Singer, Yifan Xu, I-Ting Angelina Lee
  https://www.cse.wustl.edu/~angelee/home_page/papers/ws-future.pdf

## Talk

- Memory abstractions for parallel programming
  I-Ting Angelina Lee
  https://www.youtube.com/watch?v=WQzftnojaDc

## C-compatible Implementation

- Fibril work-stealing scheduler
  Chaoran Yang
  https://github.com/chaoran/fibril

## The main issues

Assuming an unbounded number of objects like tasks:
- They are created in one thread and moved to another
- They might be allocated rapidly
- On each thread, we have last-in first-out
- In-between threads there is no ordering
- After usage, they are destroyed or recycled but not from the creating thread.
- We need heuristics to return memory to the OS on unbalanced long-running tasks (say scientific simulations)

Hardware constraints:
- We want a portable solution compatible with C calling convention. Cilk solution for example is not suitable.
- We want a cross hardware solution. Fibril solution requires assembly to save registers and so is last resort.

## Using value objects instead

We can completely avoid the cactus stack issue by not heap-allocate.

On minor issues:
- It might also mean potential stack overflows.
- This means a lot of copies in the channels and work-stealing deques.
  To be benchmarked, which is cheaper and more maintainable:
    - moving 192 bytes a lot
    - going through locks and atomics for thread-safe heap alloc/release
- Nim GC is scanning stacks conservatively for cycle detection
  This means that everything that looks like a pointer will be checked against ref objects.

On major issues:
- With value objects the deques size is bounded or needs to be growed as-demand.
- For long-lived programs, we might never release the memory if we use a container
  that doesn't shrink as the deques is only released at runtime end.

### Staccato

As far as I am aware, Staccato is the only work-stealing scheduler using tasks as value object
to completely avoid the cactus stack problem.
Note that Staccato tasks only have 3 pointers (24 bytes) of metadata.

When benchmarking they have less overhead than any other framework on fibonacci on my machine (18 hyperthreaded cores at 4.1Ghz):
  - 2x less channel-based work-stealing with LazyFutures
  - 5x less overhead than Intel TBB
  - 20x less overhead than LLVM OpenMP
  - ∞ less overhead than GCC OpenMP (which just chokes due to using a global task queue)

Quoting from the author of Staccato:
> Internal data structures of most work-stealing schedulers are designed with an assumption that they would store memory pointers to task objects. Despite their low overhead, this approach have the following problems:
>
> 1. For each task memory allocator should be accessed twice: to allocate task object memory and then to free it, when the task is finished. It brings allocator-related overhead.
> 2. There's no guarantee that tasks objects will be stored in adjacent memory regions. During tasks graph execution this leads to cache-misses overhead.
>
> In my implementation these problems are addressed by:
>
> 1. Designing a deque based data structure that allows to store tasks objects during their execution. So when the task is completed its memory is reused by the following tasks, which eliminates the need for accessing memory manager. Besides, this implementation has lesser lock-contention than traditional work-stealing deques.
> 2. Using dedicated memory manager. As deques owner executes tasks in LIFO manner, its memory access follows the same pattern. It allows to use LIFO based memory manager that does not have to provide fragmentation handling and thread-safety thus having lowest overhead possible and stores memory object in consecutive memory.
>
> As a drawback of this approach is that you have to specify the maximum number of subtasks each task can have. For example, for classical tasks of calculating Fibonacci number it's equal to 2. For majority of tasks it's not problem and this number is usually known at developing stage, but I plan bypass this in the future version.

  - Staccato work-stealing scheduler
    https://github.com/rkuchumov/staccato

## Sketch of a portable solution

### Design goals

- (if value object)
  Support an unbounded number of tasks in the deques
- (if heap alloc)
  Memory can be allocated in one thread and released in another
- Keep overhead in thread-local context as much as possible to avoid locks/atomics
- Keep allocations close together
- Allocations are aligned to a cache-line
- Low memory overhead:
  Memory can be released to the OS for long-running processes
- Low CPU overhead:
  Most of the time is spent on computation, not bookkeeping

### Analysis

#### Value objects

Using a growable container is possible, it is even more easy with private deques as there is no need for
atomics (see: [cpp-taskflow growable workstealing deque](https://github.com/cpp-taskflow/cpp-taskflow/blob/e64be5bcd0aeace4ef052437df22611bfc68cc0c/taskflow/core/spmc_queue.hpp#L194-L200))

Memory of the deques will not be released to the OS but
we do not have an issue with memory of the tasks never being returned.

#### Heap allocated

We don't have an issue with an unbounded number of tasks in the deque but we have an issue with
memory fragmentation, memory locality and returning memory from arbitrary threads.

We could have a 2-stage solution a thread-local cache sitting on top of a multi-threaded system allocator
or a custom tailored pool allocator tuned for our cactus stack.

##### Stage 2 - At the thread level

A thread-local cache of pointers, implemented as a circular buffer of fixed capacity, for example 16 slots.
If all slots are filled, adding a new one will overwrite the oldest. Free tasks are taken in LIFO order
as the last one is probably hotter in cache.

_Note: the current solution intrusive stack is similar but grows unbounded and never releases memory to the main allocator_

Pseudocode:
```Nim
type
  CircularStack[C: static int, T: ptr] = object
    pos, len: int
    buffer: array[C, T]
    # allocator: Allocator[T] # we assume that T defines a `allocate` proc instead

  proc push[C, T](buf: var CircularStack[C, T], x: sink T) =
    # Assuming a destructor on T that returns to the multithreaded allocator (including the OS one)
    `=sink`(buffer[pos], x)
    buf.pos = (buf.pos + 1) mod C
    if buf.len < C:
      # If not at max capacity, we have more in cache
      inc buf.len

  proc pop[C, T](buf: var CircularStack[C, T]): owned T =
    if buf.len > 0:
      # We assumes moving will nil pointers
      assert not buf.buffer[buf.pos].isNil
      result = move buf.buffer[buf.pos]
      buf.pos = (C + buf.pos - 1) mod C
      buf.len -= 1
    else:
      result = allocate(T)
```

Alternatively, since our tasks have `prev` and `next` fields available we can implement an intrusive circular stack.
Implementation is left as an exercise to the reader.
It would probably be much slower due to the cost of dereferencing tasks at each push/pop.

##### Stage 1 - Allocator / object pool

We can use Nim or the system allocator or develop a tailored object pool.

- The object pool only needs to support a fixed size type.
- It is over the long-term used in a stack-like pattern.
- The number of objects in-flight is unbounded, its at minimum the user workload "forking factor" multiplied by the number of threads.
- There is a thread local cache, oldest entries are returned to this pool.
- Any thread can request or return memory.
- We want to return blocks of unused memory to the OS.

### Inspiration from threaded allocators

#### Mimalloc

Since we want just a multithreaded object pool and not a full-blown allocator
a simple design would suffice.

The recent Mimalloc exhibits excellent performance, excellent memory usage.
Furthermore instead of using a free list per object size, their free list is sharded
by page. Since we only have one object size in our allocator, sharding by page is more relevant

- Paper: https://www.microsoft.com/en-us/research/uploads/prod/2019/06/mimalloc-tr-v1.pdf
- Repo: https://github.com/microsoft/mimalloc
- Benchmarks: https://github.com/daanx/mimalloc-bench

#### QT Multithreaded Pool Allocator

This article goes over the skeleton of a threadsafe growable pool allocator (but does not return memory):

https://www.qt.io/blog/a-fast-and-thread-safe-pool-allocator-for-qt-part-1
