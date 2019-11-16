# Weave, a state-of-the-art multithreading runtime

_"Good artists borrow, great artists steal."_ -- Pablo Picasso

Weave (codenamed "Project Picasso") is a multithreading runtime for the [Nim programming language](https://nim-lang.org/)

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
  which corresponds to 3.33 ms on a 3 GHz CPU to amortize the cost of scheduling.
  This burden the developers with questions of grain size, heuristics on distributing parallel loop
  for the common case and mischeduling on recursive tree algorithms with potentially very low compute-intensive leaves.
  - Weave uses an adaptative work-stealing scheduler that adapts its stealing strategy depending
    on each core load and the intensity of tasks.
    Small tasks will be packaged into chunks to amortize scheduling overhead.
  - Weave also uses an adaptative lazy loop splitting strategy.
    Loops will only be split when needed. There is no partitioning issue or grain size issue,
    or estimating if the workload is memory-bound or compute-bound, see [PyTorch OpenMP woes on parallel map](https://github.com/zy97140/omp-benchmark-for-pytorch).
  - Weave aims efficient multicore scaling for very fine-grained tasks starting from the 200 cycles range upward (67 µs on 3GHz).
    Note that Weave benchmarks are done with granularities of 1µs, 10µs and 100µs.
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

Weave is based on the research by [Andreas Prell](https://github.com/aprell/).
You can read his [PhD Thesis](https://epub.uni-bayreuth.de/2990) or access his [C implementation](https://github.com/aprell/tasking-2.0).

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. These files may not be copied, modified, or distributed except according to those terms.
