# Project Picasso

Project Picasso is the codename for a new multithreading runtime
for Nim.

It will profit from Nim lightweight borrow-checker
and state-of-the-art work-stealing schedulers research
to provide an efficient, ergonomic and scalable multithreading runtime.

_"Good artists borrow, great artists steal."_ -- Pablo Picasso

The challenges Picasso answers are discussed here:
https://github.com/nim-lang/RFCs/issues/160

It's available in this repo for your convenience in [](picasso_RFC.md).
For high-level API discussions please post in the original thread.
Low-level discussions, bugs, implementations should be discussed in this repo.

## Low-level details

The low-level details of Picasso reflect what I am optimizing for:

- Fast:
    Picasso is optimized for throughput.
- Portable:
    Picasso should be portable anywhere there is a C compiler and message-passing (or locks).
    Public deques based work-stealing schedulers
    cannot work efficiently on platforms without shared-memory and atomics (Cell CPU, distributed computers)
- Adaptative and fine-grained:
    Current CPUs are sporting a high number of cores: 16+.
    However real workload are often hard to divide into
    big enough chunks for that much number of cores unless in specific domains like numerical computing.
    Picasso should allow efficient parallelization of fine-grained tasks.
    I.e. as long as the runtime has already been started
    any tasks that takes at minimum 10-100 microseconds is worth parallelizing.
    Furthermore, Picasso should be adaptative and should not require developers to hardcode grain size, chunk size or other load distribution magic parameters while their programs will run on wildly different platforms, architecture, number of cores, caches, NUMA architecture, load or even virtualized.
- Composable:
    Multiple Nim libraries using Picasso
    should not kill the performance for everyone.
    A parallel library calling another one should result in
    proper load balancing and not oversubscription of resources.
- Low memory and codesize footprint:
    Picasso should be usable on SoC
    and "edge" devices that start offering quad-core CPUs.
- Low profile:
    Picasso should have low overheads. Time and space were already mentioned,
    Picasso also focus on not stressing memory allocators
    and not fragmenting memory with careless allocations
- Maintainable:
    Tooling and instrumentation to inspect Picasso are provided.
- Scalable (long-term goal):
    Picasso should be NUMA-aware as memory-coherency seems to reach its limit,
    and even enthusiasts CPU are starting to ship with NUMA (AMD Ryzen 2990WX)
    Picasso should be extensible with cluster capabilities (OpenMPI), Heterogeneous Computing (different compute capabilities, machines with GPU)

As such this leads to the following:

- Picasso is not optimized for real-time or latency:
  It can be used in latency critical applications like games
  however there is no fairness or no system like a priority queue to ensure
  that a job finishes in priority.

  The goal is to process the **total** work
  as fast as possible, fast processing of **individual** piece of work
  is a side-effect.

- Picasso is message-passing based, all communications go through channels, this include the synchronization between cores for scheduling but also
  the memory pools for shared objects.

- Picasso implements state-of-the-art dynamic load balancing including
  lazy loop splitting and adaptative stealing to package or split tasks
  depending on real-time conditions.

- Picasso follows a future model, similar to async/await for IO
  and multiplex an arbitrary number of user tasks on limited kernel threads.

- There is a tradeoff between inlining for performance
  and bloating the code. Decisions are made carefully.

  Similarly the instantiation of generics and static (monomorphization)
  requires duplicating code that the C/C++ compiler or linker is not able
  to eliminate even when it is possible (typed pointers that could be type-erased).
  Duplicating obviously increase the code size but
  also adversely affect CPU caches.

  Use of generics and statics is a tradeoff between type-safety,
  runtime performance and code size.

- Picasso should not adversely affecty a well-design library by
  wildly fragmenting the heap even if said library request
  millions of futures and tasks and so millions of intermediate allocations.

- The codebase includes options to dissect the runtime performance
  and potential bugs within the runtime.
  Benchmarks and extra toolings will be used to ensure performance and correctness.

- The use of message-passing which is the only way to communicate between
  multiple machines should allow Picasso to be extensible with
  established specifications like MPI.
  More research is needed for NUMA and GPU work distribution.
