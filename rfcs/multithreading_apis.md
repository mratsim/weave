---
rfc: -1
title: Executors, multithreading, channels APIs
author: Mamy André-Ratsimbazafy (@mratsim)
type: Library interoperability standard
category: Multithreading
status: Draft
created: YYYY-MM-DD
license: CC0 1.0 Universal
---

# Executors, multithreading, channels APIs

## Abstract

This document:
- introduces common vocabulary related to multithreading, managing tasks and execution resources.
- defines an API for fork-join parallelism. Threadpools and parallelism libraries SHOULD implement this API.
- defines an API for inter-thread communication via channels.
  Channels library SHOULD implement this API.

## Table of Contents

- [Executors, multithreading, channels APIs](#executors-multithreading-channels-apis)
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
        - [Local executor](#local-executor)
        - [Global executor](#global-executor)
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
  - [Experimental Task Parallelism API](#experimental-task-parallelism-api)
    - [Creating a task](#creating-a-task-1)
      - [`submit`: scheduling MUST NOT block the submitter thread [Experimental]](#submit-scheduling-must-not-block-the-submitter-thread-experimental)
  - [Channels](#channels-1)
  - [Non-goals](#non-goals)
    - [Definitions](#definitions-1)
    - [Non-goals not covered](#non-goals-not-covered)
  - [References](#references)

## Introduction

The Nim programming language has significantly evolved since its threadpool and channels modules were introduced in the standard library.
- Channels, introduced in 2011 (https://github.com/nim-lang/Nim/blob/99bcc233/lib/system/inboxes.nim) as `inboxes.nim` likely with the idea of making first-class actors in Nim.
- Threadpool, introduced in 2014 (https://github.com/nim-lang/Nim/pull/1281) along with compiler implementation of `spawn` and `parallel`.

Since then, few projects actually used channels or threadpools in part due to:
- Lack of polish, showing up as lack of how-tos or many bugs or reimplementation of primitives.
- Thread-local GC complicating inter-thread communication.
- Competing solutions like OpenMP `||`.

With the progress of core low-level primitives and compiler guarantees, Nim foundations are becoming solid enough to build an ergonomic and safe multithreading ecosystem.

This document specifies the multithreading interfaces related to channels and threadpools so that they can be evolved or replaced with principled foundations.
This document is interested in the public user API and does not specify the underlying implementation.
This document does not require compiler support. Primitives can be implemented as a library.
This document also defines related multithreaded concepts that may be implemented in some libraries without specifying them. The interface is left open until more feedback is gathered.
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

##### Local executor

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

##### Global executor

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

This allows users to know if the current thread would block or not.

### Error handling

Procs that are spawned MUST NOT throw an exception. They MAY throw `Defect` which would end the program.
Exceptions must be trapped by `try/except` blocks and converted to another form of error handling such as status codes, error codes or `Result[T, E]` type.

Threadpool and task parallelism libraries SHOULD document that constraint to end users and SHOULD enforce tht constraint with the effect system.

### Thread-local variables

Procs that are spawned MUST NOT use thread-local storage unless they are internal to the executor library.
Executors make no guarantees about the thread of execution.

Threadpool and task parallelism libraries SHOULD document that constraint to end users.

### Cancellation

This RFC does not require cancellation primitives.

Rationales:
- no CPU-bound workflow expect cancellations.
- without premptive multitasking, which can only be implemented in a kernel, an hardware thread cannot be suspended without cooperation.

Alternative:
- A cancellable computation should have a "cancellation token" parameter which would be a channel that would be checked at predetermined points in the computation.

## Experimental Task Parallelism API

### Creating a task

#### `submit`: scheduling MUST NOT block the submitter thread [Experimental]

`submit` is a tentative alternative to `spawn` that guarantees execution on a different thread.
Similar to `spawn` the API would be:
```
macro submit(ex: MyExecutor, procCall: typed{nkCall | nkCommand}): Pending or void
  ## Executor-local submit
macro submit(procCall: typed{nkCall | nkCommand}): Pending or void
  ## Global submit
```

It is left unspecified for now as given the competing latency (IO schedulers) vs throughput (CPU schedulers) requirements, there might be no use case for `submit` that isn't better covered by allowing multiple specialized schedulers in a program.

`submit`, `Job`, `runInBackground(Weave)` and `setupSubmitterThread(Weave)` were added to Weave following
- https://github.com/mratsim/weave/issues/132
- https://github.com/mratsim/weave/pull/136
to improve interoperability with async event loops by allowing a thread to submit `Job` to an executor
while guaranteeing that execution always happens in a different thread from the async thread.

## Channels

TODO

## Non-goals

### Definitions

### Non-goals not covered

- Common closure, continuation and/or task type might
- Structured parallelism
- OpenMP
- Services & producer-consumer architecture
- Cancellation
- Data parallelism
- Dataflow parallelism
- Async/await
- Closures, Continuations & Tasks
- Distributed computing

## References

- Project Picasso
- Next steps for CPS
- Completing the Async-Await
