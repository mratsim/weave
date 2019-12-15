# Weave, a state-of-the-art multithreading runtime
[![Build Status: Travis](https://img.shields.io/travis/com/mratsim/weave?label=Travis%20%28Linux%2FMac%20-%20x86_64%2FARM64%29)](https://travis-ci.com/mratsim/weave)
[![Build Status: Azure](https://img.shields.io/azure-devops/build/numforge/69bc2700-4fa7-4292-a0b3-331ddb721640/2?label=Azure%20%28C%2FC%2B%2B%20Linux%2032-bit%2F64-bit%29)](https://dev.azure.com/numforge/Weave/_build?definitionId=2&branchName=master)
[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)

_"Good artists borrow, great artists steal."_ -- Pablo Picasso

Weave (codenamed "Project Picasso") is a multithreading runtime for the [Nim programming language](https://nim-lang.org/).

⚠️ At the moment, Weave only works on Linux and MacOS. The only missing part for Windows
is wrapping [Synchronization Barriers](https://docs.microsoft.com/en-us/windows/win32/sync/synchronization-barriers) (which is much better than MacOS where you have to write the barrier from scratch).

> ⚠️ Disclaimer:
>
> The synchronization primitives were not formally verified
> or model-checked to prove the absence of data races or deadlock/livelock,
> nor were they passed under a data race detection tool.
>
> Individual components are tested and the benchmarks as well,
> however the potential interleaving of hundreds of threads for
> billions of tasks and memory accesses was not.
>
> Weave does limit synchronization to only simple SPSC and MPSC channels which greatly reduces
> the potential bug surface.

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

  transpose(M, N, bufIn, bufOut)

main()
```

### Strided loops

You might want to use loops with a non unit-stride, this can be done with the following syntax.

```Nim
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
- `sync(Flowvar)` will await a Flowvar and block until you receive a result.
- `sync(Weave)` is a global barrier for the main thread on the main task. Allowing nestable barriers for any thread is work-in-progress.
- `parallelFor`, `parallelForStrided`, `parallelForStaged`, `parallelForStagedtrided` are described above and in the experimental section.
- `loadBalance(Weave)` gives the runtime the opportunity to distribute work. Insert this within long computation as due to Weave design, it's busy workers hat are also in charge of load balancing. This is done automatically when using `parallelFor`.
- `isSpawned` allows you to build speculative algorithm where a thread is spawned only if certain conditions are valid. See the `nqueens` benchmark for an example.
- `getThreadId` returns a unique thread ID. The thread ID is in the range 0 ..< number of threads.

The max number of threads can be configured by the environment variable WEAVE_NUM_THREADS
and default to your number of logical cores (including HyperThreading).
Weave uses Nim's `countProcessors()` in `std/cpuinfo`

## Table of Contents

- [Weave, a state-of-the-art multithreading runtime](#weave-a-state-of-the-art-multithreading-runtime)
  - [API](#api)
    - [Task parallelism](#task-parallelism)
    - [Data parallelism](#data-parallelism)
    - [Strided loops](#strided-loops)
    - [Complete list](#complete-list)
  - [Table of Contents](#table-of-contents)
  - [Experimental features](#experimental-features)
    - [Parallel For Staged](#parallel-for-staged)
    - [Lazy Allocation of Flowvars](#lazy-allocation-of-flowvars)
    - [Backoff mechanism](#backoff-mechanism)
  - [Limitations](#limitations)
  - [Statistics](#statistics)
  - [Tuning](#tuning)
  - [Unique features](#unique-features)
  - [Research](#research)
  - [License](#license)

## Experimental features

### Parallel For Staged

Weave provides a `parallelForStaged` construct with supports for thread-local prologue and epilogue.

A parallel sum would look like this:
```Nim
proc sumReduce(n: int): int =
  let res = result.addr
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

### Lazy Allocation of Flowvars

Flowvars can be lazily allocated, this reduces overhead by at least 2x on very fine-grained tasks like Fibonacci or Depth-First-Search that may spawn trillions on tasks in less than
a couple hundreds of milliseconds. This can be enabled with `-d:WV_LazyFlowvar`.

⚠️ This only works for Flowvar of a size up to your machine word size (int64, float64, pointer on 64-bit machines)

### Backoff mechanism

A Backoff mechanism is available for preview, that allow workers with no tasks to sleep instead of spining aimlessly and burning CPU.

This can be enabled with `-d:WV_EnableBackoff=on`.
It will become the default in the future.

⚠️ The backoff mechanism is currently prone to deadlocks where a worker sleeps
and never replies anymore leaving the other workers hanging.

## Limitations

Weave cannot work with GC-ed types. Pass a pointer around or use Nim channels which are GC-aware.
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
