# Weave, a state-of-the-art multithreading runtime
[![Build Status: Travis](https://img.shields.io/travis/com/mratsim/weave/master?label=Travis%20%28Linux%20x86_64%2FARM64%29)](https://travis-ci.com/mratsim/weave)
[![Build Status: Azure](https://img.shields.io/azure-devops/build/numforge/69bc2700-4fa7-4292-a0b3-331ddb721640/2/master?label=Azure%20%28Linux%2064-bit%2C%20Windows%2064-bit%2C%20MacOS%2064-bit%29)](https://dev.azure.com/numforge/Weave/_build?definitionId=2&branchName=master)

[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)

_"Good artists borrow, great artists steal."_ -- Pablo Picasso

Weave (codenamed "Project Picasso") is a multithreading runtime for the [Nim programming language](https://nim-lang.org/).

It is continuously tested on Linux, MacOS and Windows for the following CPU architectures: x86, x86_64 and ARM64.

Weave aims to provide a composable, high-performance, ultra-low overhead and fine-grained parallel runtime that frees developers from the common worries of
"are my tasks big enough to be parallelized?", "what should be my grain size?", "what if the time they take is completely unknown or different?" or "is parallel-for worth it if it's just a matrix addition? On what CPUs? What if it's exponentiation?".

Thorough benchmarks track Weave performance against industry standard runtimes in C/C++/Cilk language on both Task parallelism and Data parallelism with a variety of workloads:
- Compute-bound
- Memory-bound
- Load Balancing
- Runtime-overhead bound (i.e. trillions of tasks in a couple milliseconds)
- Nested parallelism

Benchmarks are issued from recursive tree algorithms, finance, linear algebra and High Performance Computing, game simulations.
In particular Weave displays as low as 3x to 10x less overhead than Intel TBB and GCC OpenMP
on overhead-bound benchmarks.

At implementation level, Weave unique feature is being-based on Message-Passing
instead of being based on traditional work-stealing with shared-memory deques.

> ⚠️ Disclaimer:
>
> Only 1 out of 2 complex synchronization primitives was formally verified
> to be deadlock-free. They were not submitted to an additional data race
> detection tool to ensure proper implementation.
>
> Furthermore worker threads are basically actors or state-machines and
> were not formally verified either.
>
> Weave does limit synchronization to only simple SPSC and MPSC channels which greatly reduces
> the potential bug surface.

## Installation

Weave can be simply installed with
```bash
nimble install weave@#master
```

or for the devel version
```bash
nimble install weave
```

Weave requires at least Nim v1.2.0

## API

### Task parallelism

Weave provides a simple API based on spawn/sync which works like async/await for IO-based futures.

The traditional parallel recursive fibonacci would be written like this:
```Nim
import weave

proc fib(n: int): int =
  # int64 on x86-64
  if n < 2:
    return n

  let x = spawn fib(n-1)
  let y = fib(n-2)

  result = sync(x) + y

proc main() =
  var n = 20

  init(Weave)
  let f = fib(n)
  exit(Weave)

  echo f

main()
```

### Data parallelism

Weave provides nestable parallel for loop.

A nested matrix transposition would be written like this:

```Nim
import weave

func initialize(buffer: ptr UncheckedArray[float32], len: int) =
  for i in 0 ..< len:
    buffer[i] = i.float32

proc transpose(M, N: int, bufIn, bufOut: ptr UncheckedArray[float32]) =
  ## Transpose a MxN matrix into a NxM matrix with nested for loops

  parallelFor j in 0 ..< N:
    captures: {M, N, bufIn, bufOut}
    parallelFor i in 0 ..< M:
      captures: {j, M, N, bufIn, bufOut}
      bufOut[j*M+i] = bufIn[i*N+j]

proc main() =
  let M = 200
  let N = 2000

  let input = newSeq[float32](M*N)
  # We can't work with seq directly as it's managed by GC, take a ptr to the buffer.
  let bufIn = cast[ptr UncheckedArray[float32]](input[0].unsafeAddr)
  bufIn.initialize(M*N)

  var output = newSeq[float32](N*M)
  let bufOut = cast[ptr UncheckedArray[float32]](output[0].addr)

  init(Weave)
  transpose(M, N, bufIn, bufOut)
  exit(Weave)

main()
```

#### Strided loops

You might want to use loops with a non unit-stride, this can be done with the following syntax.

```Nim
import weave

init(Weave)

# expandMacros:
parallelForStrided i in 0 ..< 100, stride = 30:
  parallelForStrided j in 0 ..< 200, stride = 60:
    captures: {i}
    log("Matrix[%d, %d] (thread %d)\n", i, j, myID())

exit(Weave)
```

### Complete list

- `init(Weave)`, `exit(Weave)` to start and stop the runtime. Forgetting this will give you nil pointer exceptions on spawn.
- `spawn fnCall(args)` which spawns a function that may run on another thread and gives you an awaitable Flowvar handle.
- `newPledge`, `fulfill` and `spawnDelayed` (experimental) to delay a task until some dependencies are met. This allows expressing precise data dependencies and producer-consumer relationships.
- `sync(Flowvar)` will await a Flowvar and block until you receive a result.
- `syncRoot(Weave)` is a global barrier for the main thread on the main task.
- `parallelFor`, `parallelForStrided`, `parallelForStaged`, `parallelForStagedStrided` are described above and in the experimental section.
- `loadBalance(Weave)` gives the runtime the opportunity to distribute work. Insert this within long computation as due to Weave design, it's busy workers hat are also in charge of load balancing. This is done automatically when using `parallelFor`.
- `isSpawned` allows you to build speculative algorithm where a thread is spawned only if certain conditions are valid. See the `nqueens` benchmark for an example.
- `getThreadId` returns a unique thread ID. The thread ID is in the range 0 ..< number of threads.

The max number of threads can be configured by the environment variable WEAVE_NUM_THREADS
and default to your number of logical cores (including HyperThreading).
Weave uses Nim's `countProcessors()` in `std/cpuinfo`

## Table of Contents

- [Weave, a state-of-the-art multithreading runtime](#weave-a-state-of-the-art-multithreading-runtime)
  - [Installation](#installation)
  - [API](#api)
    - [Task parallelism](#task-parallelism)
    - [Data parallelism](#data-parallelism)
      - [Strided loops](#strided-loops)
    - [Complete list](#complete-list)
  - [Table of Contents](#table-of-contents)
  - [Platforms supported](#platforms-supported)
    - [C++ compilation](#c-compilation)
    - [Windows 32-bit](#windows-32-bit)
    - [Resource-restricted devices](#resource-restricted-devices)
  - [Backoff mechanism](#backoff-mechanism)
    - [Weave using all CPUs](#weave-using-all-cpus)
  - [Experimental features](#experimental-features)
    - [Data parallelism (experimental features)](#data-parallelism-experimental-features)
      - [Awaitable loop](#awaitable-loop)
      - [Parallel For Staged](#parallel-for-staged)
      - [Parallel Reduction](#parallel-reduction)
    - [Dataflow parallelism](#dataflow-parallelism)
      - [Delayed computation with single dependencies](#delayed-computation-with-single-dependencies)
      - [Delayed computation with multiple dependencies](#delayed-computation-with-multiple-dependencies)
      - [Delayed loop computation](#delayed-loop-computation)
    - [Lazy Allocation of Flowvars](#lazy-allocation-of-flowvars)
  - [Limitations](#limitations)
  - [Statistics](#statistics)
  - [Tuning](#tuning)
  - [Unique features](#unique-features)
  - [Research](#research)
  - [License](#license)

## Platforms supported

Weave supports all platforms with `pthread` and Windows.
Missing pthread functionality may be emulated or unused.
For example on MacOS, the `pthread` implementation does not expose barrier functionality or affinity settings.

### C++ compilation

At the moment C++ compilation is not available on latest Nim + latest Weave.

The new "dataflow parallelism" feature that
allows delaying parallel tasks depending on arbitrary conditions
requires a data structure (`Pledge`) that is valid in C but invalid in C++.

C++ compilation works with the following combination:
- Weave v0.3.0
- Nim devel [@bf2e052e](https://github.com/nim-lang/Nim/commit/bf2e052e6d97c1117603480547804dd98d1ada71)

### Windows 32-bit

Windows 32-bit targets cannot use the MinGW compiler as it is missing support
for `EnterSynchronizationBarrier`. MSVC should work instead.

### Resource-restricted devices

Weave uses a flexible and efficient memory subsystem that has been optimized for a wide range of hardware: low power Raspberry Pi, phones, laptops, desktops and 30+ cores workstations.
It currently assumes by default that 16KB at least are available on your hardware for a memory pool and that this memory pool can grow as needed.
This can be tuned with `-d:WV_MemArenaSize=2048` to have the base pool use 2KB for example.
The pool size should be a multiple of 256 bytes.
PRs to improve support of very restricted devices are welcome.

## Backoff mechanism

A Backoff mechanism is enabled by default. It allows workers with no tasks to sleep instead of spinning aimlessly and burning CPU cycles.

It can be disabled with `-d:WV_Backoff=off`.

### Weave using all CPUs

Weave multithreading is cooperative, idle threads send steal requests instead of actively stealing in other workers queue.

This means that a thread sleeping or stuck in a long computation may starve other threads and they will spin burning CPU cycles.

- Don't sleep or block a thread as this blocks Weave scheduler. This is a similar to `async`/`await` libraries.
- If you really need to sleep or block the main thread, make sure to empty all the tasks beforehand with `syncRoot(Weave)` in the main thread. The child threads will be put to sleep until new tasks are spawned.
- The `loadBalance(Weave)` call can be used in the middle of heavy computations to force the worker to answer steal requests. This is automatically done in `parallelFor` loops.

## Experimental features

Experimental features might see API and/or implementation changes.

For example both parallelForStaged and parallelReduce allow for reduction but
parallelForStaged is more flexible, it however requires explicit use of locks and/or atomics.

LazyFlowvars may be enabled by default for certain sizes or if escape analysis become possible
or if we prevent Flowvar from escaping their scope.

### Data parallelism (experimental features)

#### Awaitable loop

Loops can be awaited. Awaitable loops return a normal Flowvar.

This blocks the thread that spawned the parallel loop from continuing until the loop is resolved. The thread does not stay idle and will steal and run other tasks while being blocked.

Calling `sync` on the awaitable loop Flowvar will return `true` for the last thread to exit the loop and `false` for the others.
- Due to dynamic load-balancing, an unknown amount of threads will execute the loop.
- It's the thread that spawned the loop task that will always be the last thread to exit.
  The `false` value is only internal to `Weave`

> ⚠️ This is not a barrier: if that loop spawns tasks (including via a nested loop) and exits, the thread will continue, it will not wait for the grandchildren tasks to be finished.

```Nim
import weave

init(Weave)

# expandMacros:
parallelFor i in 0 ..< 10:
  awaitable: iLoop
  echo "iteration: ", i

let wasLastThread = sync(iLoop)
echo wasLastThread

exit(Weave)
```


#### Parallel For Staged

Weave provides a `parallelForStaged` construct with supports for thread-local prologue and epilogue.

A parallel sum would look like this:
```Nim
proc sumReduce(n: int): int =
  let res = result.addr # For mutation we need to capture the address.
  parallelForStaged i in 0 .. n:
    captures: {res}
    prologue:
      var localSum = 0
    loop:
      localSum += i
    epilogue:
      echo "Thread ", getThreadID(Weave), ": localsum = ", localSum
      res[].atomicInc(localSum)

  sync(Weave)

init(Weave)
let sum1M = sumReduce(1000000)
echo "Sum reduce(0..1000000): ", sum1M
doAssert sum1M == 500_000_500_000
exit(Weave)
```

`parallelForStagedStrided` is also provided.

#### Parallel Reduction

Weave provides a parallel reduction construct that avoids having to use explicit synchronization like atomics or locks
but instead uses Weave `sync(Flowvar)` under-the-hood.

Syntax is the following:

```Nim
proc sumReduce(n: int): int =
  var waitableSum: Flowvar[int]

  # expandMacros:
  parallelReduceImpl i in 0 .. n, stride = 1:
    reduce(waitableSum):
      prologue:
        var localSum = 0
      fold:
        localSum += i
      merge(remoteSum):
        localSum += sync(remoteSum)
      return localSum

  result = sync(waitableSum)

init(Weave)
let sum1M = sumReduce(1000000)
echo "Sum reduce(0..1000000): ", sum1M
doAssert sum1M == 500_000_500_000
exit(Weave)
```

In the future the `waitableSum` will probably be not required to be declared beforehand.
Or parallel reduce might be removed to only keep parallelForStaged.

### Dataflow parallelism

Dataflow parallelism allows expressing fine-grained data dependencies between tasks.
Concretly a task is delayed until all its dependencies are met and once met,
it is triggered immediately.

This allows precising specification of data producer-consumer relationships.

In contrast, classic task parallelism can only express control-flow dependencies (i.e. parent-child function calls relationships) and classic tasks are eagerly scheduled.

In the literature, it is also called:
- Stream parallelism
- Pipeline parallelism
- Graph parallelism
- Data-driven task parallelism

Tagged experimental as the API and its implementation are unique
compared to other libraries/language-extensions. Feedback welcome.

No specific ordering is required between calling the pledge producer and its consumer(s).

Dependencies are expressed by a handle called `Pledge`.
A pledge can express either a single dependency, initialized with `newPledge()`
or a dependencies on parallel for loop iterations, initialized with `newPledge(start, exclusiveStop, stride)`

To await on a single pledge `singlePledge` pass it to `spawnDelayed` or the `parallelFor` invocation.
To await on an iteration `iterPledge`, pass a tuple:
- `(iterPledge, 0)` to await precisely and only for iteration 0. This works with both `spawnDelayed` or `parallelFor`
- `(iterPledge, myIndex)` to await on a whole iteration range. This only works with `parallelFor`. The `Pledge` iteration domain and the `parallelFor` domain must be the same. As soon as a subset of the pledge is ready, the corresponding `parallelFor` tasks will be scheduled.

#### Delayed computation with single dependencies

```Nim
import weave

proc echoA(pA: Pledge) =
  echo "Display A, sleep 1s, create parallel streams 1 and 2"
  sleep(1000)
  pA.fulfill()

proc echoB1(pB1: Pledge) =
  echo "Display B1, sleep 1s"
  sleep(1000)
  pB1.fulfill()

proc echoB2() =
  echo "Display B2, exit stream"

proc echoC1() =
  echo "Display C1, exit stream"

proc main() =
  echo "Dataflow parallelism with single dependency"
  init(Weave)
  let pA = newPledge()
  let pB1 = newPledge()
  spawnDelayed pB1, echoC1()
  spawnDelayed pA, echoB2()
  spawnDelayed pA, echoB1(pB1)
  spawn echoA(pA)
  exit(Weave)

main()
```

#### Delayed computation with multiple dependencies

```Nim
import weave

proc echoA(pA: Pledge) =
  echo "Display A, sleep 1s, create parallel streams 1 and 2"
  sleep(1000)
  pA.fulfill()

proc echoB1(pB1: Pledge) =
  echo "Display B1, sleep 1s"
  sleep(1000)
  pB1.fulfill()

proc echoB2(pB2: Pledge) =
  echo "Display B2, no sleep"
  pB2.fulfill()

proc echoC12() =
  echo "Display C12, exit stream"

proc main() =
  echo "Dataflow parallelism with multiple dependencies"
  init(Weave)
  let pA = newPledge()
  let pB1 = newPledge()
  let pB2 = newPledge()
  spawnDelayed pB1, pB2, echoC12()
  spawnDelayed pA, echoB2(pB2)
  spawnDelayed pA, echoB1(pB1)
  spawn echoA(pA)
  exit(Weave)

main()
```

#### Delayed loop computation

You can combine data parallelism and dataflow parallelism.

Currently parallel loops only support one dependency (single, fixed iteration or range iteration).

Here is an example with a range iteration dependency. _Note: when sleeping threads are unresponsive, meaning a sleeping thread cannot schedule other ready tasks._

```Nim
import weave

proc main() =
  init(Weave)

  let pA = newPledge(0, 10, 1)
  let pB = newPledge(0, 10, 1)

  parallelFor i in 0 ..< 10:
    captures: {pA}
    sleep(i * 10)
    pA.fulfill(i)
    echo "Step A - stream ", i, " at ", i * 10, " ms"

  parallelFor i in 0 ..< 10:
    dependsOn: (pA, i)
    captures: {pB}
    sleep(i * 10)
    pB.fulfill(i)
    echo "Step B - stream ", i, " at ", 2 * i * 10, " ms"

  parallelFor i in 0 ..< 10:
    dependsOn: (pB, i)
    sleep(i * 10)
    echo "Step C - stream ", i, " at ", 3 * i * 10, " ms"

  exit(Weave)

main()
```

### Lazy Allocation of Flowvars

Flowvars can be lazily allocated, this reduces overhead by at least 2x on very fine-grained tasks like Fibonacci or Depth-First-Search that may spawn trillions of tasks in less than
a couple hundreds of milliseconds. This can be enabled with `-d:WV_LazyFlowvar`.

⚠️ This only works for Flowvar of a size up to your machine word size (int64, float64, pointer on 64-bit machines)
⚠️ Flowvars cannot be returned in that mode, you will at best trigger stack smashing protection or crash

## Limitations

Weave has not been tested with GC-ed types. Pass a pointer around or use Nim channels which are GC-aware.
If it works, a heads-up would be valuable.

This might improve with Nim ARC/newruntime.

## Statistics

Curious minds can acces the low-level runtime statistic with the flag `-d:WV_metrics`
which will give you the information on number of tasks executed, steal requests sent, etc.

Very curious minds can also enable high resolution timers with `-d:WV_metrics -d:WV_profile -d:CpuFreqMhz=3000` assuming you have a 3GHz CPU.

The timers will give you in this order:
```
Time spent running tasks, Time spent recv/send steal requests, Time spent recv/send tasks, Time spent caching tasks, Time spent idle, Total
```

## Tuning

A number of configuration options are available in [weave/config.nim](weave/config.nim).

In particular:
- `-d:WV_StealAdaptativeInterval=25` defines the number of steal requests after which thieves reevaluate their steal strategy (steal one task or steal half the victim's tasks). Default: 25
- `-d:WV_StealEarly=0` allows worker to steal early, when only `WV_StealEraly tasks are leftin their queue. Default: don't steal early

## Unique features

Weave provides an unique scheduler with the following properties:
- Message-Passing based:
  unlike alternative work-stealing schedulers, this means that Weave is usable
  on any architecture where message queues, channels or locks are available and not only atomics.
  Architectures without atomics include distributed clusters or non-cache coherent processors
  like the Cell Broadband Engine (for the PS3) that favors Direct memory Access (DMA),
  the many-core mesh Tile CPU from Mellanox (EzChip/Tilera) with 64 to 100 ARM cores,
  or the network-on-chip (NOC) CPU Epiphany V from Adapteva with 1024 cores,
  or the research CPU Intel SCC.
- Scalable:
  As the number of cores in computer is growing steadily, developers need to find new avenues of parallelism
  to exploit them.
  Unfortunately existing framework requires computation to take 10000 cycles at minimum (Intel TBB)
  which corresponds to 3.33 µs on a 3 GHz CPU to amortize the cost of scheduling.
  This burden the developers with questions of grain size, heuristics on distributing parallel loop
  for the common case and mischeduling on recursive tree algorithms with potentially very low compute-intensive leaves.
  - Weave uses an adaptative work-stealing scheduler that adapts its stealing strategy depending
    on each core load and the intensity of tasks.
    Small tasks will be packaged into chunks to amortize scheduling overhead.
  - Weave also uses an adaptative lazy loop splitting strategy.
    Loops will only be split when needed. There is no partitioning issue or grain size issue,
    or estimating if the workload is memory-bound or compute-bound, see [PyTorch OpenMP woes on parallel map](https://github.com/zy97140/omp-benchmark-for-pytorch).
  - Weave aims efficient multicore scaling for very fine-grained tasks starting from the 2000 cycles range upward (0.67 µs on 3GHz).
- Fast and low-overhead:
  While the number of cores have been growing steadily, many programs
  are now hitting the limit of memory bandwidth and require tuning allocators,
  cache lines, CPU caches.
  Enormous care has been given to optimize Weave to keep it very low-overhead.
  Weave uses efficient memory allocation and caches to avoid stressing
  the system allocator and prevent memory fragmentation.
  Soon, a thread-safe caching system that can release memory to the OS will be added
  to prevent reserving memory for a long-time.
- Ergonomic and composable:
  Weave API is based on futures similar to async/await for concurrency.
  The task dependency graph is implicitly built when awaiting a result
  An OpenMP-syntax is planned.

The "Project Picasso" RFC is available for discussion in [Nim RFC #160](https://github.com/nim-lang/RFCs/issues/160)
or in the (potentially outdated) [picasso_RFC.md](Weave_RFC.md) file

## Research

Weave is based on the research by [Andreas Prell](https://github.com/aprell/).
You can read his [PhD Thesis](https://epub.uni-bayreuth.de/2990) or access his [C implementation](https://github.com/aprell/tasking-2.0).

Several enhancements were built into Weave, in particular:

- Memory management was carefully studied to allow releasing memory to the OS
  while still providing very high performance and solving the decades old cactus stack problem.
  The solution, coupling a threadsafe memory pool with a lookaside buffer, is
  inspired by Microsoft's Mimalloc and Snmalloc, a message-passing based allocator (also by Microsoft). Details are provided in the multiple Markdown file in the [memory folder](weave/memory).
- The channels were reworked to not use locks. In particular the MPSC channel (Multi-Producer Single-Consumer) supports batching for both producers and consumers without any lock.

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. These files may not be copied, modified, or distributed except according to those terms.
