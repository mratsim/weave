---
rfc: -1
title: Executors, task parallelism, channels APIs
author: Mamy André-Ratsimbazafy (@mratsim)
type: Library interoperability standard
category: Multithreading
status: Draft
created: YYYY-MM-DD
license: CC0 1.0 Universal
---

# Executors, task parallelism, channels APIs

## Abstract

This document:
- introduces common vocabulary related to multithreading, managing tasks and execution resources.
- defines an API for task parallelism via the fork-join model. Threadpools and parallelism libraries SHOULD implement this API.
- defines an API for inter-thread communication via channels.
  Channels libraries SHOULD implement this API.

## Table of Contents

- [Executors, task parallelism, channels APIs](#executors-task-parallelism-channels-apis)
  - [Abstract](#abstract)
  - [Table of Contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Requirements Notation](#requirements-notation)
  - [Definitions](#definitions)
    - [Channels](#channels)
    - [Closures](#closures)
    - [Concurrency](#concurrency)
    - [Continuations](#continuations)
    - [Executor & execution context](#executor--execution-context)
    - [Parallelism](#parallelism)
      - [Fork-join model](#fork-join-model)
      - [Task parallelism](#task-parallelism)
    - [Task](#task)
    - [Threadpool](#threadpool)
    - [Threads & Fibers](#threads--fibers)
  - [Task Parallelism API](#task-parallelism-api)
    - [Creating a task](#creating-a-task)
      - [`spawn`: scheduling left to the executor [REQUIRED]](#spawn-scheduling-left-to-the-executor-required)
        - [Local executor API](#local-executor-api)
        - [Global executor API](#global-executor-api)
        - [Future handle](#future-handle)
        - [Scheduling](#scheduling)
    - [Awaiting a future [REQUIRED]](#awaiting-a-future-required)
      - [Awaiting a single future [REQUIRED]](#awaiting-a-single-future-required)
      - [Awaiting multiple futures [UNSPECIFIED]](#awaiting-multiple-futures-unspecified)
      - [Structured parallelism [OPTIONAL]](#structured-parallelism-optional)
    - [Check if a task was spawned [REQUIRED]](#check-if-a-task-was-spawned-required)
    - [Check if a result has been computed [REQUIRED]](#check-if-a-result-has-been-computed-required)
    - [Error handling](#error-handling)
    - [Thread-local variables](#thread-local-variables)
    - [Cancellation](#cancellation)
  - [Buffered channels](#buffered-channels)
    - [Non-blocking send [REQUIRED]](#non-blocking-send-required)
    - [Non-blocking receive [REQUIRED]](#non-blocking-receive-required)
    - [Blocking send [OPTIONAL]](#blocking-send-optional)
    - [Blocking receive [OPTIONAL]](#blocking-receive-optional)
    - [Batched operations [OPTIONAL]](#batched-operations-optional)
    - [Elements count [OPTIONAL]](#elements-count-optional)
  - [Non-goals](#non-goals)
    - [Experimental non-blocking Task Parallelism API](#experimental-non-blocking-task-parallelism-api)
      - [Creating a task](#creating-a-task-1)
        - [`submit`: scheduling MUST NOT block the submitter thread [Experimental]](#submit-scheduling-must-not-block-the-submitter-thread-experimental)
    - [Definitions](#definitions-1)
    - [Non-goals not covered](#non-goals-not-covered)

## Introduction

The Nim programming language has significantly evolved since its threadpool and channels modules were introduced in the standard library.
- Channels, introduced in 2011 (https://github.com/nim-lang/Nim/blob/99bcc233/lib/system/inboxes.nim) as `inboxes.nim` likely with the idea of making first-class actors in Nim.
- Threadpool, introduced in 2014 (https://github.com/nim-lang/Nim/pull/1281) along with compiler implementation of `spawn` and `parallel`.

Since then, few projects actually used channels or threadpools in part due to:
- Lack of polish, showing up as lack of how-tos or many bugs or reimplementation of primitives.
- Thread-local GC complicating inter-thread communication.
- Competing solutions like OpenMP `||`.

With the progress of core low-level primitives and compiler guarantees, Nim foundations are becoming solid enough to build an ergonomic and safe multithreading ecosystem.

This document specifies the multithreading interfaces related to channels and threadpools so that they can be evolved or replaced with principled foundations.\
This document is interested in the public user API and does not specify the underlying implementation.\
This document does not require compiler support. Primitives can be implemented as a library.\
This document also defines related multithreaded concepts that may be implemented in some libraries without specifying them. The interface is left open until more feedback is gathered.\
This document is written under the assumptions that there is no one-size-fits-all and that projects may want to use multiple threadpools, executors or schedulers within the same application or library. Furthermore, libraries may offer to support multiple parallelism backends and as a project evolves dedicated specialized threadpools may be written that are tuned to specific workloads.

The core primitives mentioned that facilitate multithreading are:
- GCs ARC and ORC which are not using thread-local heaps
  - https://forum.nim-lang.org/t/5734
  - https://nim-lang.org/blog/2020/10/15/introduction-to-arc-orc-in-nim.html
- Destructors which allow transferring ownership of non-GC types
  - https://nim-lang.org/docs/destructors.html
- `Isolated[T]` which allow transferring ownership of GC types
  - https://github.com/nim-lang/RFCs/issues/244

This blog post explains why it's important to embrace multiple schedylers:
- https://nim-lang.org/blog/2021/02/26/multithreading-flavors.html

Multithreading is a very large subject that cannot be covered in a single specification. Nonetheless to facilitate future RFCs, this document will define terms that are likely to come up in future specifications in a non-goals section.

While channels and task parallelism API are presented in the specification document, they MAY be implemented in different libraries.

## Requirements Notation

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in the Internet Engineering Task Force (IETF) [BCP14](https://tools.ietf.org/html/bcp14) [RFC2119](https://tools.ietf.org/html/rfc2119) [RFC8174](https://tools.ietf.org/html/rfc8174) when, and only when, they appear in all capitals, as shown here.

## Definitions

Definitions are ordered in lexicographical order. Definitions may include specification or implementation recommendation.

### Channels

A channel is a cross-thread communication queue or ring-buffer.

A channel can come in many flavors:
- single-producer or multi-producer
- single-consumer or multi-consumer
- list-based or array-based or hybrid
  - If list-based:
    - intrusive linked list or non-intrusive
- bounded or unbounded
  - if bounded:
    - Errors on reaching bounds
    - Blocks on reaching bounds
    - Overwrite the oldest item on reaching bounds (ring-buffer)
- lock-based or atomic-based
- progress guarantees:
  - no guarantees (whether using locks or atomics)
  - obstruction-free
  - lockfree
  - waitfree
- priorities support
- item ordering guarantees
  - no guarantees
  - serializability
  - linearizability
- Buffered or unbuffered (rendez-vous)

Note: not using locks does not imply that a channel is lockfree.
`lockfree` is a progress guarantee, even without locks an implementation can block.
We call such channels `lockless`. It is worth noting that usually the stronger the progress guarantees the less throughput your channel has. Strong progress guarantees are needed for low-latency or real-time processing.

For reference types, a channel transfers ownership of the reference.
A channel MUST NOT copy, this is required for both correctness and performance.

Shared ownership requires ensuring that the shared object is not freed twice and not freed before its last users.
- One solution requires manually managed `ptr object` and ensuring that the thread that will free the shared object awaits all child tasks.
- Another solution requires wrapping the type in an atomic reference-counted pointer. Its implementation is left as an exercise to the reader.

### Closures

A closure is a data structure representing procedure and its parameters (environment).

For multithreading purpose, it MUST be using a threadsafe memory allocator and/or garbage collection. Nim closures with Nim default refc GC is not compatible with multithreading.
Closures SHOULD be non-copyable, only movable. A closure might free a temporary resource at the end of a computation (CPU or GPU memory, a socket, a database handle), that resource might be manually managed or managed by destructors.

### Concurrency

Concurrency is the ability to make progress on more than one task at a time.
Parallelism imply concurrency but concurrency does not imply parallelism.
A program may interleave execution of task A, then task B, then task A on a single thread and be concurrent and not parallel.

Since IO workloads requires waiting to make progress and CPU workloads require working to make progress, concurrency is often associated with IO-bound tasks and parallelism with CPU-bound tasks.

### Continuations

A continuation represents the state of execution of a program at a certain point.

Running a continuation would restore that state and run the program from that point.

Concretely, a continuation is a data structure with a procedure that represents the following statements (instructions) to run and all the parameters required to run them (environment).

At a data structure level, a closure and a continuation have the same fields.

### Executor & execution context

An executor is a handle to an execution context. An execution context represents:
- a pool of threads (CPU and/or GPU).
- a scheduler that selects which thread to assign a task to.
- one or more collections of pending tasks.
- one or more collections of sleeping threads.

### Parallelism

Parallelism is the ability to physically run part of a program on multiple hardware resources at the same time.

#### Fork-join model

The fork-join model allows execution of a program to branch off ('fork') on two threads at designated points in the programs. The forks can be 'joined' at designated points.

Fork points are often called `spawn` including in Nim threadpool. Join points are often called `sync`. They are called `^` in Nim threadpool.

The fork-join model can be implemented on top of:
- hardware threads, using OS `fork()`.
- fibers
- a threadpool

At a fork point, multiple dispatching strategies can be used, for example on parallel merge sort:
```Nim
proc mergeSort[T](a, b: var openarray[T]; left, right: int) =
  if right - left <= 1: return

  let middle = (left + right) div 2
  let fut = spawn mergeSort(a, b, left, middle) # <-- Fork child task
  # ------------------------------------------------- Everything below is the continuation
  mergeSort(a, b, middle, right)
  sync(fut)                                     # <-- Join
  merge(a, b, left, middle, right)
```
At the `spawn` points:
- `mergeSort(a, b, left, middle)` can be packaged in a closure and sent to an executor, becoming a `task`. The current threads then executes the next line `mergeSort`.
  This is called help-first scheduling because the current thread helps creating new tasks first. It is also called child-stealing because the executor steals the child task.
- The continuation `mergeSort(a, b, middle, right); sync(fut); merge(a, b, left, middle, right)` can be packaged and sent to an executor. The current thread then suspends the current procedure and enters the spawned `mergeSort`.
  This is called work-first scheduling because the current thread work immediately on new tasks. It is also called continuation-stealing and parent-stealing because the executor steals the continuation of the current (parent) procedure.

A high-level overview of continuation-stealing vs child-stealing is given in
- A Primer on Scheduling via work-stealing (continuation stealing or child task stealing): http://www.open-std.org/Jtc1/sc22/wg21/docs/papers/2014/n3872.pdf

#### Task parallelism

Task parallelism dispatches heterogeneous (procedure, data) pairs on execution resources.

The fork-join model is the usual way to split a program into tasks.

### Task

A task is a data structure representing a procedure, its parameters (environment) and its execution context.

Closures MAY be packaged in a task.
The task data structure is left unspecified.

### Threadpool

A threadpool is an executor with a naive scheduler that has no advanced load balancing technique.

### Threads & Fibers

A thread is a collection of execution resources:
- a stack
- a computation to do

With OS (or kernel) threads, the stack is managed by the kernel.

Userspace threads where the library allocates, switches and manages its own stack are called fibers (and also stackful coroutines). [`std/coro`](https://nim-lang.org/docs/coro.html) is an implementation of fibers.

GPUs also have threads, their stack is managed by the GPU driver.

## Task Parallelism API

Task parallelism is implemented via the fork join model. This is the model used in:
- std/threadpool, https://nim-lang.org/docs/threadpool.html
- https://github.com/yglukhov/threadpools
- https://github.com/mratsim/weave (Weave also implements data parallelism and dataflow parallelism)

The API has a REQUIRED and OPTIONAL interface. Some APIs are unspecified.

The API intentionally mirrors async/await without reusing the names to differentiate between concurrency (async/await) and parallelism (spawn/sync).

### Creating a task

#### `spawn`: scheduling left to the executor [REQUIRED]

A task-parallel executor MUST implement either the local executor or the global executor API.
It MAY implement both.

##### Local executor API

A new task MUST be created on a specific executor with a template or macro with the following signature

```Nim
macro spawn(ex: MyExecutor, procCall: typed{nkCall | nkCommand}): FlowVar or void
  ## Executor-local spawn
```

For example

```Nim
# var pool: MyExecutor
# ...
let fut = pool.spawn myFunc(a, b, c)
```

##### Global executor API

A new task MUST be created on a global executor with a template or macro with the following signature

```Nim
macro spawn(procCall: typed{nkCall | nkCommand}): FlowVar or void
  ## Global spawn
```

For example

```Nim
let fut = spawn myFunc(a, b, c)
```

Disambiguation between global executors can be done by prefixing the module name.

```Nim
let fut = threadpool.spawn myFunc(a, b, c)
```

Global executors MAY use a dummy type parameter to refer to their global executor.

```Nim
macro spawn(_: type MyExecutor, procCall: typed{nkCall | nkCommand}): FlowVar or void
  ## Global spawn

let fut = MyExecutor.spawn myFunc(a, b, c)
```

##### Future handle

`spawn` should return a future handle under the type `FlowVar[T]` or `void`.
`T` is the type returned by the procedure being forked. If it returns `void`, `spawn` returns `void`.

If the future of a void procedure is needed, the end user SHOULD wrap that function in a function with a return value, for example a function that returns `bool` or refactor their code.

##### Scheduling

`spawn` is a hint to the executor that processing MAY happen in parallel.
The executor is free to schedule the code on a different thread or not depending on hardware resources, current load and other factors.

At a `spawn` statement, the threadpool implementation may choose to have the current thread execute the child task (continuation-stealing) or the continuation (child-stealing).

Scheduling is done eagerly, there is no abstract computation graph being built that is launched at a later point in time.

### Awaiting a future [REQUIRED]

The operation to await a task-parallel future is called `sync`.
This leaves `await` open for async libraries and framework.
It is also the usual name used in multithreading framework, going back to Cilk (1995).

#### Awaiting a single future [REQUIRED]

Program execution can be suspended until a `Flowvar` is completed by calling `sync` on a `Flowvar`.

```Nim
proc sync(fv: sink FlowVar[T]): T
  ## Global spawn
```

The `Flowvar` MUST be associated with a spawned task.

A `Flowvar` can only by synced once, hence the return value within the `FlowVar[T]` can be moved.

A `Flowvar` MUST NOT be copied, only moved. This SHOULD be enforced by overloading `=copy`

```Nim
proc `=copy`(dst: var FlowVar[T], src: FlowVar[T]) {.error: "A FlowVar cannot be copied".}
```

If a `Flowvar` is created and awaited within the same procedure, the `Flowvar` MAY use heap allocation elision as an optimization to reduce heap allocation.

At a `sync` statement, the current thread SHOULD participate in running the executor tasks. The current thread MAY choose to only take tasks that the awaited `Flowvar` depends on.

#### Awaiting multiple futures [UNSPECIFIED]

Awaiting multiple futures ("await until any" or "await until all") is unspecified.

#### Structured parallelism [OPTIONAL]

Structured parallelism ensures that all tasks and their descendants created within a scope are completed before exiting that scope.

```Nim
template syncScope(ex: MyExecutor, scope: untyped): untyped
template syncScope(scope: untyped): untyped
```

References:
- X10 Parallel Programming Language (2004), the Async-Finish construct
- Habanero multithreading runtime for Java and Scala, the Async-Finish construct
- Habanero C, the Async-Finish construct

More recently, concurrency frameworks also converged to similar "structured concurrency" (https://en.wikipedia.org/wiki/Structured_concurrency).

### Check if a task was spawned [REQUIRED]

And user can call `isSpawned()` to check if a `Flowvar` is associated with a spawned task.

```Nim
proc isSpawned(fv: Flowvar): bool
```

This allows users to build speculative algorithms that may or may not spawn tasks (unbalanced task tree), for example nqueens with backtracking.

### Check if a result has been computed [REQUIRED]

An user can call `isReady` on a `Flowvar` to check if the result is present.

```Nim
proc isReady(fv: Flowvar): bool
```

The `Flowvar` MUST be associated with a spawned task.

This allows users to know if the current thread would block or not when calling `sync` on A Flowvar.

### Error handling

Procs that are spawned MUST NOT throw an exception. They MAY throw `Defect` which would end the program.
Exceptions MUST be trapped by `try/except` blocks and converted to another form of error handling such as status codes, error codes or `Result[T, E]` type.

Threadpool and task parallelism libraries SHOULD document that constraint to end users and SHOULD enforce tht constraint with the effect system.

Note: even assuming C++ exceptions, or exceptions that don't use the heap or a GC without thread-local heap, exceptions work by unwinding the stack. As each thread has its own stack, you cannot catch exceptions thrown in a thread in another.

### Thread-local variables

Procs that are spawned MUST NOT use thread-local storage unless they are internal to the executor library.
Executors make no guarantees about the thread of execution.

Threadpool and task parallelism libraries SHOULD document that constraint to end users.

### Cancellation

This RFC does not require cancellation primitives so that the caller can cancel the callee.

Rationales:
- no CPU-bound workflow expect cancellations.
- without premptive multitasking, which can only be implemented in a kernel, a hardware thread cannot be suspended without cooperation.

Alternative:
- A cancellable computation should have a "cancellation token" parameter which would be a channel that would be checked at predetermined points in the computation.

## Buffered channels

Channels are a basic inter-thread communication primitive.
This specifies buffered channels, i.e. channels that can hold at least one item.

Unbuffered channels, also called rendez-vous channels, are unspecified.

The channel flavors should be communicated clearly in-particular:
- whether it's single or multi producer and consumer.
  - A single-producer single-consumer channel is called SPSC
  - A multi-producer single-consumer channel is called MPSC
  - A single-producer multi-consumer channel is called SPMC
  - A multi-producer multi-consumer channel is called MPMC

  There are 2 kinds of SPMC queues:
  - a broadcast queue which duplicates all message enqueued to all consumers.
  - a "racing" queue that gives the message to the first consumer to request it.

  For channels we only specify the "racing" type, a broadcasting channel can be implemented on top of SPSC channels.
- whether its bounded or unbounded
  - The behavior (errors, blocks or overwrites oldest) if bound is reached
- the progress guarantees
  - no guarantees
  - obstruction-free
  - lock-free
  - wait-free
- the item ordering guarantees:
  - no guarantees
  - serializability
  - linearizability
- whether the channel is intrusive (requires a `next: Atomic[T]` with T a `ptr object`) or not

### Non-blocking send [REQUIRED]

```
func trySend*[T](chan: var Chan, src: sink Isolated[T]): bool =
  ## Try sending an item into the channel
  ## Returns true if successful (channel had enough free slots)
  ##
  ## ⚠ Use only in the producer thread that writes from the channel.
```
### Non-blocking receive [REQUIRED]

```
proc tryRecv[T](chan: var Chan, dst: var Isolated[T]): bool =
  ## Try receiving the next item buffered in the channel
  ## returns true if an item was found and moved to `dst`
  ##
  ## ⚠ Use only in a consumer thread that reads from the channel.
```
### Blocking send [OPTIONAL]

```
func send*[T](chan: var Chan, src: sink Isolated[T]): bool =
  ## Send an item into the channel
  ## (Blocks/Overwrites oldest) if channel if full
  ## Returns true if the channel was full and mitigation strategy was needed.
  ##
  ## ⚠ Use only in the producer thread that writes from the channel.
```

Blocking send still returns a bool for backpressure management.
If blocking or overwriting the oldest is chosen, sending is always successful if the function returns.
### Blocking receive [OPTIONAL]

```
proc recv[T](chan: var Chan, dst: var Isolated[T]): bool =
  ## Receive the next item buffered in the channel
  ## Blocks and returns true if no item is present
  ## Returns the item immediately and returns false if no blocking was needed.
  ##
  ## ⚠ Use only in a consumer thread that reads from the channel.
```

Blocking receive still returns a bool for backpressure management.

### Batched operations [OPTIONAL]

We define batch operations for list-based channels.

```Nim
proc trySendBatch[T](chan: var Chan, bFirst, bLast: sink Isolated[T], count: SomeInteger): bool =
  ## Send a linked list of items to the back of the channel
  ## They should be linked together by their next field.
  ## `count` refer to the number of items in the list.
  ## Returns true if successful (channel had enough free slots)

proc tryRecvBatch[T](chan: var Chan, bFirst, bLast: var Isolated[T]): int =
  ## Try receiving all items buffered in the channel
  ## Returns true if at least some items are dequeued.
  ## There might be competition with producers for the last item
  ##
  ## Items are returned as a linked list
  ## Returns the number of items received
  ##
  ## If no items are returned bFirst and bLast are undefined
  ## and should not be used.
  ##
  ## The `next` field in `bLast` is undefined.
  ## nil or overwrite it for further use in linked lists
```

Working with integers in a synchronization primitive like channel MUST NOT throw an exception.

### Elements count [OPTIONAL]

Channels MAY keep track of the elements enqueued or dequeued.
In that case they MAY provide an approximate count of items with `peek`.

Working with integers in a synchronization primitive like channel MUST NOT throw an exception.

`peek` MUST NOT block the caller.
Due to the non-deterministic nature of multithreading, even if a channel is locked to get the exact count, it would become an approximation as soon as the channel is unlocked.

If called on a channel with a single consumer, from the consumer thread, the approximation is a lower bound as producers can enqueue items concurrently.
If called on a channel with a single producer, from the producer thread, the approximation is a lower bound as consumers can dequeue items concurrently.
If called on a channel with multiple producers, from a producer thread, no conclusion is possible as other producers enqueues items and the consumer(s) thread dequeue(s) them concurrently.
Similarly on a channel with multiple consumers, from a consumer thread.

API + documentation on a MPSC channel.

```Nim
func peek*(chan: var Chan): int =
  ## Estimates the number of items pending in the channel
  ## - If called by the consumer the true number might be more
  ##   due to producers adding items concurrently.
  ## - If called by a producer the true number is undefined
  ##   as other producers also add items concurrently and
  ##   the consumer removes them concurrently.
  ##
  ## This is a non-locking operation.
```

## Non-goals
### Experimental non-blocking Task Parallelism API

In the proposed API, the scheduler may have the spawning thread participate in clearing the work queue(s)
at `sync` statements.
If the spawning thread is handling network or UI event this is would block network or UI handling,
in that case it is desirable to ensure that the work cannot happen in the spawning thread.
This proposes `submit`, `Job`, `Pending` that mirror `spawn`, `Task`, `Flowvar`.

It is left unspecified for now as given the competing latency (IO schedulers) vs throughput (CPU schedulers) requirements, there might be no use case for `submit` that isn't better covered by allowing multiple specialized schedulers in a program.

Alternatively, the application could be separated in an UI/networking thread and a heavy processing thread with the heavy processing thread managing a threadpool.

#### Creating a task

##### `submit`: scheduling MUST NOT block the submitter thread [Experimental]

`submit` is a tentative alternative to `spawn` that guarantees execution on a different thread.
Similar to `spawn` the API would be:
```
macro submit(ex: MyExecutor, procCall: typed{nkCall | nkCommand}): Pending or void
  ## Executor-local submit
macro submit(procCall: typed{nkCall | nkCommand}): Pending or void
  ## Global submit
```

`submit`, `Job`, `runInBackground(Weave)` and `setupSubmitterThread(Weave)` were added to Weave following
- https://github.com/mratsim/weave/issues/132
- https://github.com/mratsim/weave/pull/136
to improve interoperability with async event loops by allowing a thread to submit `Job` to an executor
while guaranteeing that execution always happens in a different thread from the async thread.

### Definitions

This section gives a definition of other terms related to multithreading and async so that there is common vocabulary within the Nim community to talk about those concepts.

However it does not specify them.

- **resumable functions**
  Traditional functions have two effects on control flow:
  1. On function call, suspend the caller, jump into the function body and run it.
  2. On reaching "return", terminate the callee, resume the caller.

  Resumable functions adds the following 2 key capabilities:
  3. The callee can suspend itself, returning control to "something".
  4. The current owner (not always the initial caller) of the function can suspend itself and resume the continuation (aka the unexecuted "rest of the function").

- **coroutines**
  Resumable functions are called coroutines if the continuation (aka the unexecuted "rest of the function") can only be called once and it is delimited in scope (we exit the function at the end and return control to the caller). "Coroutines are one-shot delimited continuations".
  Coroutines that uses the stack of their caller (like a normal function) are called stackless coroutines.
  As a reminder fibers (stackful coroutines or green threads) allocate some memory and move the stack pointer to it (with assembly) just like hardware thread.
  **Closure iterators** are stackless coroutines.
  Note: stackful vs stackless is about the function call stack (stacktraces) nor about stack vs heap allocation of the coroutine state.

- **CPU-bound vs IO-bound tasks**:
  See https://nim-lang.org/blog/2021/02/26/multithreading-flavors.html

- **Latency**:
  The time required to wait to receive the result of 1 unit of work.
  Latency is often important for IO and most important for real-time.
  A single client/consumer of a service only cares about its latency

- **Throughput**
  The time required to expedite all units of work.
  Throughput is often important for CPU-bound tasks where all work need to be expedited,
  and the order it is done is inconsequential, for example for batch transforming 1000 images,
  it doesn't matter whether we start from the first or the last as long as all are done as fast as possible.

- **Data parallelism**
  While task parallelism is the ability to run different tasks in parallel,
  data parallelism is the ability to run the same task, but parallelizing at the data level,
  for exemple dividing an array of size N so that each core receives an equal share of work.
  This is often presented as a parallel for loop.

- **Dataflow parallelism**
  Dataflow parallelism is the ability to specify task or data dependencies and schedule the resulting computation graph in parallel.
  Dataflow parallelism is presented under either:
  - building an explicit graph
  - using events associated with tasks and triggered by other tasks
  - declarative "in", "out", "depends", "inout" annotations
  Dataflow parallelism is used to model complex pipelined computations, for example video processing
  where certain areas of the video might be less complex and so, in that area, later steps of processing can start earlier.
  Dataflow parallelism is also called:
  - Stream parallelism
  - Pipeline parallelism
  - Graph parallelism
  - Data-driven task parallelism

### Non-goals not covered

- Closures, Continuations & Tasks
- OpenMP
- Services & producer-consumer architecture
- Data parallelism
- Dataflow parallelism
- Async/await interaction
- Distributed computing
- Spawning anonymous functions
