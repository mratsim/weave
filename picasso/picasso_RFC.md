# Project Picasso - a multithreading runtime for Nim

_"Good artists borrow, great artists steal." -- Pablo Picasso_

Originally posted at: https://github.com/nim-lang/RFCs/issues/160

## Introduction

The Nim destructors and new runtime were introduced
to provide a GC-less path forward for Nim libraries and applications
where it made sense. One of their explicit use cases is making threading easier.

## RFC goals

This RFC aims
- to present the current challenges and the design space of
multithreading runtime.
- collect use-cases and discuss goals and non-goals of a multi-threaded runtime.
- understand if we need compiler support for some features and if not:
  - discuss if we should allow competing runtimes and allow switching
  just like Nim allows multiple GCs (refcounting, mark-and-sweep, boehm, no gc).
- gather some metrics ideas to benchmark runtime systems.
- ultimately have people implementing a runtime system or part of (there are plenty of pieces needed)

The problem domain:

The word "thread" had [many meanings in the past](https://en.wikipedia.org/wiki/Threaded_code) or words closely related (green threads vs heavy threads, coroutines, fibers, ...).

I.e. threading means how to interleave different routines and their contexts of execution.

This RFC focuses on "heavy" threads as used for computation on multi-core systems.

## Why Project Picasso?

The new runtime introduced a **borrow-checker** and most successful
multithreading runtimes uses **work-stealing** for load balancing.
Now re-read the quote :wink:.

## Table of contents
<!-- TOC -->

- [Project Picasso - a multithreading runtime for Nim](#project-picasso---a-multithreading-runtime-for-nim)
  - [Introduction](#introduction)
  - [RFC goals](#rfc-goals)
  - [Why Project Picasso?](#why-project-picasso)
  - [Table of contents](#table-of-contents)
  - [Reading on Nim related concepts](#reading-on-nim-related-concepts)
  - [Where are we now?](#where-are-we-now)
  - [Brief overview of the types of parallelism](#brief-overview-of-the-types-of-parallelism)
    - [What are we interested in?](#what-are-we-interested-in)
  - [Use-cases](#use-cases)
  - [API](#api)
  - [Load-balancing](#load-balancing)
  - [Scheduler implementation](#scheduler-implementation)
  - [Hardware](#hardware)
    - [Memory](#memory)
  - [Extras](#extras)
  - [Benchmarking](#benchmarking)
  - [Community challenges](#community-challenges)

<!-- /TOC -->
## Reading on Nim related concepts

- Araq's blog posts on concurrency (2013)
  - https://nim-lang.org/araq/concurrency.html
  - https://nim-lang.org/araq/concurrency2.html

- Destructors (2017)
  - https://nim-lang.org/araq/destructors.html
  - https://github.com/nim-lang/Nim/wiki/Destructors,-2nd-edition

- Newruntime, owned refs, borrow-checking (2019)
  - https://nim-lang.org/araq/ownedrefs.html
  - https://github.com/nim-lang/RFCs/issues/144

## Where are we now?

If you want to use multiple cores in Nim you can currently use

- Raw threads via `createThread` (pthreads on Unix, Fibers on Windows)
- Threadpool with
  - the `spawn`/`^` functions
  - The `parallel` statement
  - channels for inter-thread communication
- OpenMP with
  - The `||` OpenMP operator for parallel for-loops or task-loops
  - Emitting [OpenMP blocks](https://github.com/numforge/laser/blob/af191c086b4a98c49049ecf18f5519dc6856cc77/laser/openmp.nim)

However, I'd argue that

- `createThread` is a too low-level abstraction for most.
- The threadpool has contention issues due to using a global queue, and it has no load balancing either.
- OpenMP does not supported nested parallelism. The implementation of tasks varies wildly (GCC's uses a global queue as well so load-balancing and contention are issues) and cannot be built upon (for example for task graphs).
  Furthermore, OpenMP requires going through C/C++ compilation
  and cannot be used with [`nlvm`](https://github.com/arnetheduck/nlvm) or [projects that would want to JIT parallel code](https://github.com/numforge/laser/tree/master/laser/lux_compiler).

## Brief overview of the types of parallelism

There are several kinds of parallelism, some addressed at the hardware level
and some addressed at the software level.

Let's start with hardware level not addressed by this RFC:

**Instruction-Level Parallelism**:

Modern [superscalar processors](https://en.wikipedia.org/wiki/Superscalar_processor) have multiple execution ports and can schedule multiple instructions at the
same time if they don't use the same port and there is no data dependency

**SIMD: Single Instruction Multiple Data**:

Often called vectorization, this is SSE, AVX, etc: one instruction but that applies to a vector of 4x, 8x, 16x integers or floats.

**SIMT: Single Instruction Multiple Threads**:

That is the threading model of a GPU. Threads are organized at the level of a Warp (Nvidia) or Wavefront (AMD) and they all execute the same instructions (with obvious bad implications for branching code).

**SMT: Simultaneous Multi-Threading**:

In Intel speak "Hyperthreading". While a superscalar processor can execute multiple instructions in parallel,
it will sometimes get idle due to instruction latency or waiting for memory.
One way to reclaim performance for a limited increase in chip size is with
HyperThreading with each physical cores having 2 (usually) to 4 logical cores siblings (Xeon Phi) that can use the same hardware resources to execute multiple threads.

Further information: https://yosefk.com/blog/simd-simt-smt-parallelism-in-nvidia-gpus.html

### What are we interested in?

**Exploiting multiple cores**:

Recent laptops now ship with 4 cores, even phones ship with 4 cores, we need to provides tools for the devs to use them.

At the software level

**Data parallelism**:

The easy part, you work on elements and your operation _maps_ to the same operation on all elements. For, incrementing all elements of an array by one.

**Task Parallelism**:

The complex part, you have tasks (jobs) that are usually different in terms of computation, resources, time required but can be scheduled in parallel. Those can produce new tasks. For example, issuing a parallel search on an unbalanced tree data-structure.

What are we less interested in

**Stream Parallelism**:

You have a data stream and apply a pipeline of transformations on it, possibly with forks in the stream and joins. An example would be a parallel iterator library or a parallel stream program that takes an input compressed image archive, decompresses it, applies transformations to some images and then recompress those in a new archive.

I believe that stream parallelism is sufficiently similar to data parallelism and task graphs
that addressing data and task parallelism will make stream processing much easier.

## Use-cases

I will need your help for this section.
Some obvious needs are:

1. `spawn computeIntensiveTask()` (Task-parallelism)
2. Array processing in numerical computing (Data parallelism)

In both cases parallelism can be nested if a parallel Nim library
calls another parallel Nim library. The system should behave properly
if a parallel GUI calls a parallel image library for example.

## API

Having good features will draw people, having good APIs will make them stay.

Here is an overview of the design space.

Data parallelism only needs 5 primitives:
- parallel section (to setup thread local values)
- parallel for
- parallel reduce
- barrier
- critical section

Task parallelism has much more needs:
- spawning a new job
- Representing a future value with `Flowvar`
- blocking (`^`) until the child task is finished
- alternatively polling with `isReady`
- scheduling continuations
- cancel a computation (user changed image on the GUI so compute is cancelled)

As you can see there is a lot of parallel with async/await IO. This is probably a good thing, i.e. use async/await for blocking IO and spawn/`^` for non-blocking compute.

For the rest, I will assume that threads are too low-level of an abstraction
and that parallel annotation (for data parallelism) and tasks (for task parallelism) are much easier and more natural to manipulate for a developer.
A runtime system should figure how to distribute those on the hardware.

Furthermore, data parallel primitives can be expressed in terms of task primitives so I will focus on tasks.

On the non-obvious choices, there is:
- How to communicate between threads
  - Message passing (i.e. Channels): _Share by communicating instead of communicate by sharing_ (from Rust and Go)
  - Shared memory:
    - atomics and locks
- For channels:
  - Have an object shared by producer(s) and consumer(s)
  - Have a Sender object and a Receiver object that statically ensure
    that it's correctly used
- How to represent a task:
  - An object
  - A concept/interface/trait
  - A closure (that captures its context)
  - A pure function
  - Note that the choice may have impact on:
    - Nim DLLs
    - C interface, which is valuable for Nim as a Python backend
      or for JIT code to tie back to Nim.
    - Hot-code reloading
- An error model:
  - No exceptions in the runtime, unless we know have thread-safe exceptions
  - Error codes
    - If yes, we need a `spawn` that accepts a Flowvar for in-place modification
  - Options?
  - A richer API like [nim-result](https://github.com/arnetheduck/nim-result)
  - Note that Nim enums can use strings
    ```Nim
    type PicassoError = enum
      Ok = "All is well"
      ThreadMemError = "Could not allocate memory to create a thread"
      TaskMemError = "Could not allocate memory to create a task"
      AlreadyCancelledError = "Task was cancelled"
    ```
    And those can be preformatted for `printf`

    `TaskmemError = "Thread %d: could not allocate memory to create a task"`
- How to ensure composition?
- How to transfer ownership between threads?
- Are there use cases where lower-level access to the threadpool is desirable?


In terms of robustness:

- message passing benefits from CSP ([Communicating Sequential Process](https://en.wikipedia.org/wiki/Communicating_sequential_processes)), which provides a formal verification framework for concurrent system that communicates via channels
- Haskell inspired C# with the [Continuation Monad](https://www.fpcomplete.com/blog/2012/06/asynchronous-api-in-c-and-the-continuation-monad). If there is one thing that Haskell does well it's composition, and also having a solid type system.

## Load-balancing

Work-stealing won both in theory and in practice. It has been proven asymptotically optimal in terms of performance.

However there are plenty
of implementation subtleties that can have heavy influence on workloads:

- What to do after spawning work:
  - Help-first: continue on the current execution context (also called child-stealing). Breadth-first task creation: on a single-thread context, with a for loop for N tasks, N tasks will be created and live before the thread will do the job one by one.
  - Work-first: jump on the freshly spawned work (also called parent-stealing or continuation stealing). This requires compiler support similar to coroutines for restoring stackframes. Breadth-first task creation: on a single-thread context, with a for loop for N tasks, only 1 task will be live resolved before the thread goes to the next.
- Steal one tasks vs Steal half tasks
- [Leapfrogging](https://cseweb.ucsd.edu/~calder/papers/PPoPP-93.pdf): work-stealing allows an **idle** worker to steal from a busy one, but what if a busy worker is blocked by an unresolved Flowvar? Allowing it to continue instead of blocking is called leapfrogging
- Loop splitting: some tasks include loops which for efficiency reasons are not split in a task for each element. But when a loop is big, it might be worth it to split it to allow other worker threads to steal it. Except that the operation within a loop might be either very cheap or very costly so the ["grain"-size matter](https://github.com/zy97140/omp-benchmark-for-pytorch), and adaptative splitting would be very nice.
- Hierarchical work-stealing: high-end processors like AMD Threadripper or Intel Xeon Bronze/Silver/Gold/Platinum have a Non-Unified Memory Architecture (NUMA). Meaning they have significantly more affinity with the memory directly attached to their cores and accessing "far" memory causes a significant penalty. In that case it is important to only steal work corresponding to the local fast memory.
- CPU consumption and latency: when a worker finds no work, does it poll, how frequently, does it yield?
- How to select theft victims?
- How to detect work termination?

Interested and not feeling overwhelmed yet? I have gathered an extensive litterature in [my research repo](https://github.com/numforge/laser/blob/master/research/runtime_threads_tasks_allocation_NUMA.md).

## Scheduler implementation

Like the choice of communication between threads, for synchronization
as scheduler needs to choose between:
- Shared memory
- Message passing
- Software Transactional Memory (database like commits and rollback based on transaction logs)

While the traditional focus has been shared memory, involving atomics and locks. I read and ported the code of a very inspirational [Message Passing based work-stealing scheduler thesis](https://epub.uni-bayreuth.de/2990/1/main_final.pdf) in [my experimental repo](https://github.com/mratsim/weave).

Haskell is the only production grade user of Software Transactional Memory.
It has caught C++ interest, here is a [good overview of the model](https://gist.github.com/graninas/c7e0a603f3a22c7e85daa4599bf92525) and the [C++ proposal](https://www.cs.rochester.edu/u/scott/papers/2019-04-29_TACO_preprint.pdf) sponsored by Michael and Scott (from the Michael-Scott concurrent queue fame). One of the main difficulties with STM is that you cannot replay side-effects.

Note that for scheduler implementation all three strategies can be formally verified as the synchronization between threads is done through a very specific data structure:
  - Shared Memory via Chase-Lev Deque see [proof on weak memory model](https://www.di.ens.fr/~zappa/readings/ppopp13.pdf)
  - Message Passing via Channels (see [CSP article](https://en.wikipedia.org/wiki/Communicating_sequential_processes))
  - STM via transaction logs

Also all 3 already had hardware support in the past (in either experimental hardware for message passing or buggy hardware for transactional memory).

Which brings us to ...

## Hardware

The hardware we choose to target will greatly influence the runtime.

Scheduling for a weak memory model like ARM, strong memory model like x86,
a workstation with 2 CPUs or a cluster for distributed computing.

For example, the Cell processor (for Playstation 3) made it impossible to implement efficient concurrent data structure. Or shared memory is impossible for distributed computing or heterogeneous architecture with GPU nodes.

Messaging-passing is often associated with overhead.

Hardware transactional memory is only supported on recent Intel chips and GCC-only and was notoriously buggy for 3 chip generations (Ivy Bridge, Haswell, Broadwell).

Note that in all cases, implementation "details" matter a lot and message passing can be as fast as shared-memory as shown by my proof-of-concept [channel-based work stealing scheduler](https://github.com/mratsim/weave/tree/master/e04_channel_based_work_stealing).

Let's talk about the biggest implementation "detail".

### Memory

For compute intensive operations the bottleneck is often not the CPU GFlop/s but the memory to keep the processor fed with data to process. This has been captured by the [roofline model](https://en.wikipedia.org/wiki/Roofline_model) and the notion of arithmetic intensity (ratio of compute operations / bytes needed to carry it). Only operations with high arithmetic intensity can use the CPU at 100%, most are bottlenecked by memory and can use 10-20% of the compute.

This means that memory locality and efficient memory allocation and reuse is key: memory pools, object pools, stack arrays with alloca, ...

Also for NUMA architecture, a NUMA aware allocator would be helpful.

I.e. concurrent data structures should probably accept an "allocator" argument.

## Extras

Some extras that are not in scope but interesting nonetheless

- relation with the async/await event loops
- fiber/coroutine pools as in Boost::fibers or the Naughty Dogs presentation ([video](https://www.gdcvault.com/play/1022186/Parallelizing-the-Naughty-Dog-Engine) and [slides](http://twvideo01.ubm-us.net/o1/vault/gdc2015/presentations/Gyrling_Christian_Parallelizing_The_Naughty.pdf)
- Task Graphs
- Dealing with GC types (as GC will still be useful)
- Mapping with GPU: beyond the obvious offloading of for-loops to GPU, Cuda and OpenCL provides a async stream and event API to offload, provide continuations and then block or poll until the computation stream has finished.

## Benchmarking

Once we have designed our unicorn™, we need to make sure it fits our performance requirements, its overhead, its scalability and how it fares against other close-to-metal language.

Here are a couple of ideas:

- Runtime overhead (Task Parallelism):
  A recursive fibonacci benchmark will quickly tell
  how much overhead the framework has because the task is completely trivial.
  It will also tell us the scalability of the task system as the number
  of tasks grows at 2^N.
  Key for performance:
  - Memory allocators
  - Having distributed task queues/deques to limit contention

- High-performance computing (Data Parallelism)
  I have implemented a [matrix multiplication in pure Nim](https://github.com/numforge/laser/blob/af191c086b4a98c49049ecf18f5519dc6856cc77/laser/primitives/matrix_multiplication/gemm.nim) as fast
  as industry-standard OpenBLAS, which is Assembly + raw pthreads.
  It requires 2 nested parallel for loop and can also be called from
  outside parallel regions as it's a basic building block for
  many scientific and machine learning workloads.
  Key for performance:
  - As long as the matrix multiplication is well implemented it's an easy task
    as workload is completely balanced (no need for stealing), tasks are long-running (work is much bigger than overhead)
    and complex enough to maximize compute as long as memory is fast enough.
  - Thread pinning will help a lot as it is very memory intensive
    and optimizations are done to keep data in L1, L2 caches and the TLB
  - Being aware of and not using hyperthreading will help because
    otherwise the physical core will be bottlenecked by memory bandwith
    to retrieve data from 2 threads operating on different matrix sections.
  Extra: would be to test on a NUMA machine.

- Load balancing (Task parallelism)
  Tree algorithms creates a lot of tasks but if the tree is unbalanced
  idle workers will need to find new work.
  An example use-case is Monte-Carlo Tree Search used in Decision Processes and Reinforcement Learning for games IA and recently in finance. In short,
  you launch simulation on diffrent branches on a tree, stopping if one is not deemed interesting but searching deeper on interesting branches.
  The Unbalanced Tree Search benchmarks is described in [this paper](https://www.cs.unc.edu/~olivier/LCPC06.pdf).
  Key for performance:
  - load balancing

- Energy usage (Task parallelism):

  When workers find no worker they should not uselessly consume CPU. A backoff mechanism is needed that still preserve latency if new work is suddenly available.
  A benchmark of energy usage while idle can be done by just checking the cpuTime (not epochTime/wallTime)
  of a workload with a single long task compared to serial.

- Single loop generating tasks (Task Parallelism)

  Such a benchmark will challenge the runtime to bundle or potential
  split work with incoming steal requests. This stresses how many consumers
  a single producer can sustain, see [Nim implementation](https://github.com/mratsim/weave/blob/7dce364670fd77f3e953a22afd66617080020b11/e04_channel_based_work_stealing/tests/spc.nim).

- A divide-and-conquer benchmark like parallel sort

- Black-and-scholes: The Black-and-Scholes equation is the building block of financial modeling.

- Wavefront scheduling (Task Graphs)
  wavefront is a pattern that often emerges in image processing when after computing pixel [i, j], you can compute pixels [[i+1, j], [i, j+1]], then [[i+2, j], [i+1, j+1], [i, j+2]]. This is also a key optimization for recurrent neural networks ([Nvidia optimization blog - step 3](https://devblogs.nvidia.com/optimizing-recurrent-neural-networks-cudnn-5/)).

See also: [A Comparative Critical Analysis ofModern Task-Parallel Runtimes](https://prod-ng.sandia.gov/techlib-noauth/access-control.cgi/2012/1210594.pdf)

## Community challenges

Let's go back from the nitty-gritty details and look into the challenge for Nim.

- Given the breadth of the needs and design space: do we want to allow multiple libraries, do we try our hands at a one-size fits all?
  - Example: real-time system and games might want scheduling with a priority queues which are hard to make concurrent and I'm not even sure about work-stealable.
- Assuming we allow multiple libraries, how to make sure end-users can use one or the other with minimal cost, does the standard library enforce an interface/concept?
- When do we ship it?

I hope you enjoyed the read.

TL;DR: Designing a multithreading runtime involve many choices, probably some conflicting ones in terms of performance, ergonomy, complexity, theoretical properties (formal verification) and hardware support.
