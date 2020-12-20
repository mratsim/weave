# Runtime: Multithreading, Task scheduling, NUMA

> Original in laser repo: https://github.com/numforge/laser/blob/d1e6ae6/research/runtime_threads_tasks_allocation_NUMA.md

Research on a multithreading runtime

Currently Laser target OpenMP but might
encounter roadblocks down the line.

Furthermore research shows that GCC libgomp has a potential bottleneck for tasking due to scheduling via a central list protected by a mutex.

A side-effect would be to better control scheduling on
NUMA and hyperthreads as hyperthreading should be scheduled on
work that shares the same L1 cache,
and NUMA nodes on work from the directly connected memory.

## Constraints

- Work for JIT (see https://github.com/numforge/laser/issues/31)
  - OpenMP doesn't though support might come in the following year (http://lists.flang-compiler.org/pipermail/flang-dev_lists.flang-compiler.org/2019-May/000197.html)
- NUMA-aware memory allocation and threading (https://github.com/numforge/laser/issues/30)
- Support nested loops.
  - Biggest design flaw of OpenMP, if the OpenMP-parallel program is called from inside another parallel section, each thread will create N new threads unless OMP_NESTED=false.
  - Lux compiler will optimize across functions so a whole NN network might only declare a single parallel region at the top, but a task queue might be better when doing graph level scheduling, for example to schedule beam search or GANs

## Research

### Memory allocation

- NUMA aware OpenMP allocator:
  ![](./media/omp_numa_alloc.png)

- From Intel's TBB: https://techdecoded.intel.io/essentials/turbocharge-your-c-code-efficient-memory-allocation-for-increased-performance/#gs.p065tg

### Hardware detail

- Memory Models: weak/relaxed and strong ordering (impact on atomics)

  https://preshing.com/20120930/weak-vs-strong-memory-models/

### Papers - Earliest Deadline First schedulers

Those schedulers optimize for latency and are suitable for real-time system
or latency constrained system (games)

- Multi-core Real-Time Scheduling for Generalized Parallel Task Models

  Saifullah et al

  https://www.cse.wustl.edu/~lu/papers/rtss11.pdf

- Scheduling Parallel Real-Time Tasks in
  Multiprocessor Platforms (PhD Thesis)

  https://repositorio-aberto.up.pt/bitstream/10216/117806/2/304244.pdf

### Papers - Parallel Depth First schedulers

Parallel Depth First Scheduler are alternatives to work-stealing schedulers.
They also have optimal asymptotic behaviour provided enough parallelism is available.

Some of the paper here compare WS and PDF, or present a hybrid approach

- A Work-Efficient Algorithm for Parallel Unordered
  Depth-First Search

  Acar, Chargueraud, Rainey

  https://www.chargueraud.org/research/2015/pdfs/pdfs_sc15.pdf

- Work Stealing Technique and Scheduling on the Critical Path

  Cerin

  https://www6.inra.fr/mia-paris/content/download/3502/34821/version/1/file/workstealingonthecriticalpath.pdf

- Scheduling Threads for Constructive Cache Sharing on CMPs

  Chen et al

  https://www.cs.cmu.edu/~guyb/papers/CGK07.pdf


- Effectively Sharing a Cache among Threads

  Blelloch, Gibbons

  http://www.cs.cmu.edu/~blelloch/papers/BlGi04.pdf

- (Slides) Parallel Scheduling
  Theory and Practice

  Blelloch

  https://www.cs.cmu.edu/~blelloch/papers/IBM08.pdf

- Low-Contention Depth-First Scheduling of Parallel Computations with Write-Once Synchronization Variables

  Fatourou

  http://www.cs.au.dk/~gerth/alcom-ft/TR/ALCOMFT-TR-01-77.ps.gz

- Space Efficient Global Scheduler for Cilk

  Hickey, Quentmeyer

  Slides: https://ocw.mit.edu/courses/electrical-engineering-and-computer-science/6-895-theory-of-parallel-systems-sma-5509-fall-2003/projects/fp_hickey_tyeler.pdf

  Paper: http://citeseerx.ist.psu.edu/viewdoc/download?doi=10.1.1.83.2857&rep=rep1&type=pdf

- Space Efficient Scheduling of Nested Parallelism

  Narlikar, Blelloch

  http://www.cs.cmu.edu/afs/cs.cmu.edu/project/scandal/public/papers/toplas.pdf

- Scheduling Threads for Low Space Requirement
  and Good Locality

  Narlikar

  http://citeseerx.ist.psu.edu/viewdoc/download?doi=10.1.1.43.4774&rep=rep1&type=pdf

- Provably Efficient Scheduling for Language with
  Fine Grained Parallelism

  Blelloch, Gibbons, Matias

  https://www.cs.cmu.edu/~guyb/papers/jacm99.pdf

### Papers - Work-Stealing schedulers

Work-stealing schedulers are the most well-known and implemented scheduler in the wild.
They have optimal asymptotic behaviour provided enough parallelism is available.

- Parallelism course: http://15418.courses.cs.cmu.edu/fall2016content/lectures/05_progperf1/05_progperf1_slides.pdf

- Vyukhov, Go scheduler: https://assets.ctfassets.net/oxjq45e8ilak/48lwQdnyDJr2O64KUsUB5V/5d8343da0119045c4b26eb65a83e786f/100545_516729073_DMITRII_VIUKOV_Go_scheduler_Implementing_language_with_lightweight_concurrency.pdf

- Proactive work stealing futures

  Singer, Xu, Lee

  https://www.cse.wustl.edu/~angelee/home_page/papers/ws-future.pdf

- Well structured futures and cache locality

  Herlihy, Liu

  https://arxiv.org/abs/1309.5301

- A Primer on Scheduling Fork-Join Parallelism with Work Stealing

  http://open-std.org/jtc1/sc22/wg21/docs/papers/2014/n3872.pdf

- The Cilk Plus Runtime System
and the Cactus Stack (course)

  http://piazza-resources.s3.amazonaws.com/jc9tfyfh36s8f/jdmcwt1p7fn41n/09fullframe.pdf

- Using Memory Mapping to Support Cactus Stacks in Work-Stealing Runtime Systems

  Lee et al

  https://pdos.csail.mit.edu/~sbw/papers/pact183a-lee.pdf

  https://www.microsoft.com/en-us/research/video/memory-abstractions-for-parallel-programming/
  (https://www.youtube.com/watch?v=WQzftnojaDc)

- A Practical Solution to the Cactus Stack Problem

  http://chaoran.me/assets/pdf/ws-spaa16.pdf

  This introduces _leapfrogging_ originally used for futures to solve
  the cactus stack problem of child-stealing based work-stealing schedulers

  Implementation: https://github.com/chaoran/fibril

- Effective cooperative scheduling of
  task-parallel applications on
  multiprogrammed parallel architectures,
  2015, Georgios Varisteas, PhD Thesis

  https://www.diva-portal.org/smash/get/diva2:861129/FULLTEXT01.pdf

- Embracing Explicit Communication in
  Work-Stealing Runtime Systems,
  2016, Andreas Prell, PhD Thesis

  https://epub.uni-bayreuth.de/2990/1/main_final.pdf

  This introduces Channel-base work-stealing

- Memory and data aware scheduling, 2018, L. Marchal, Research Director Thesis,

  https://hal.inria.fr/tel-01934712/document

  http://perso.ens-lyon.fr/loris.marchal/hdr/slides.pdf

- Task scheduling for runtime-assisted parallelism

  http://pages.cs.wisc.edu/~adityav/Task_Scheduling_For_Runtime_Assisted_Parallelism.pdf

  Explores NUMA architecture, includes 2D convolution scheduling in benchmarks

- A NUMA-Aware Provably-Efficient Task-Parallel
  Platform Based on the Work-First Principle

  https://arxiv.org/pdf/1806.11128.pdf

- The Data Locality of Work Stealing

  https://www.cs.cmu.edu/~guyb/papers/locality2000.pdf

- Optimizing Work Stealing Algorithms with Scheduling Constraints

  J.J. Lifflander, 2016, Thesis

  https://pdfs.semanticscholar.org/a0ab/00a23377f333ca4c34dac2b74abc5af6ca25.pdf

  This thesis explores low-overhead tracing, optimization
  of work-stealing for NUMA and distributed memory systems.

- Asymmetry-aware workstealing runtime

  http://www.csl.cornell.edu/~moyang/pdfs/torng-aaws-isca2016.pdf

- Using Memory Mapping to Support Cactus Stacks in
Work-Stealing Runtime Systems

  http://supertech.csail.mit.edu/papers/stacks.pdf

- Resilient work stealing

  https://arxiv.org/pdf/1706.03539.pdf

  Introduces Cobra, a work-stealing scheduler with restartable task graphs

- Correct and Efficient Work-Stealing for Weak Memory Models

  https://www.di.ens.fr/~zappa/readings/ppopp13.pdf

- Work stealing on the critical path

  http://mao.imag.fr/reu03avr08/Cerin_paper.pdf

- Scheduling Parallel Programs by
Work Stealing with Private Deques

  Acar, Chargueraud, Rainey

  https://www.chargueraud.org/research/2013/ppopp/full.pdf

- Dynamic Circular Work-Stealing Deque

  https://www.dre.vanderbilt.edu/~schmidt/PDF/work-stealing-dequeue.pdf

- Work-First and Help-First Scheduling Policies for Async-Finish Task Parallelism

  https://www.cs.rice.edu/~yguo/pubs/PID824943.pdf

  Work-first is now known as continuation stealing and help-first as child stealing

- Executing Dynamic Task Graph via work stealing

  https://www.cse.wustl.edu/~kunal/resources/Papers/nabbit.pdf

- Leapfrogging: A portable technique for implementing efficient futures

  https://cseweb.ucsd.edu/~calder/papers/PPoPP-93.pdf

- Scheduling Multithreaded Computations by Work Stealing
  http://supertech.csail.mit.edu/papers/steal.pdf

### Implementation: Shared memory parallelism and tasking

- Julia / PARTR, Parallel Depth-First Scheduler

  https://github.com/kpamnany/partr

- Julia PARTR, technical presentation, Kiran Pamnany

  https://www.youtube.com/watch?v=YdiZa0Y3F3c

- Work Stealing CppCon 2015, Pablo Halpern

  https://www.youtube.com/watch?v=iLHNF7SgVN4

  This introduces the important distinction between
  - child stealing, implementable as a library, where
    the task creator
    - creates a closure with the environment needed
      for the execution of the child task
    - continues work on the parent.
    This creates stalls at "join" points and an unbounded
    queue space for unexecuted childs.
  - continuation stealing or parent stealing where
    the task creator
    - saves the stack pointer,
    - continues work on the child
    - a thief can resume at the saved task pointer
    This avoids closure creation and consumes bounded stack space
    but requires compiler support
    to check if the parent task was stolen or not.

  TBB uses child stealing while cilk uses continuation stealing

- Molecular Matters tutorial:

  - https://blog.molecular-matters.com/2015/08/24/job-system-2-0-lock-free-work-stealing-part-1-basics/
  - https://blog.molecular-matters.com/2015/09/08/job-system-2-0-lock-free-work-stealing-part-2-a-specialized-allocator/
  - https://blog.molecular-matters.com/2015/09/25/job-system-2-0-lock-free-work-stealing-part-3-going-lock-free/
  - https://blog.molecular-matters.com/2015/11/09/job-system-2-0-lock-free-work-stealing-part-4-parallel_for/
  - https://blog.molecular-matters.com/2016/04/04/job-system-2-0-lock-free-work-stealing-part-5-dependencies/

  - Third party implementation:

    https://github.com/cdwfs/cds_job

- Parallelizing the Naughty Dogs Engine using Fibers.

  This is a latency-optimized scheduler unlike work-stealing

  - https://gdcvault.com/play/1022186/Parallelizing-the-Naughty-Dog-Engine

    Slides: http://twvideo01.ubm-us.net/o1/vault/gdc2015/presentations/Gyrling_Christian_Parallelizing_The_Naughty.pdf

  - Third party implementations
    - https://github.com/RichieSams/FiberTaskingLib
    - https://github.com/SergeyMakeev/TaskScheduler

- OpenMP benchmarks with regards to grain size. showcasing the limits
  of static loop scheduling heuristics depending on hardware.

  https://github.com/zy97140/omp-benchmark-for-pytorch

- How Ubisoft Montreal develops Games for multicore

  https://www.youtube.com/watch?v=X1T3IQ4N-3g

- Intel's GameTechDev GamesTaskScheduler

  https://github.com/GameTechDev/GTS-GamesTaskScheduler

- Go's work-stealing scheduler

  https://rakyll.org/scheduler/

- A Comparative Critical Analysis of Modern Task-Parallel Runtimes

  https://prod-ng.sandia.gov/techlib-noauth/access-control.cgi/2012/1210594.pdf

- OMP proc_bind for NUMA-aware threading
  ![](./media/omp_proc_bind.png)

- Intel's Thread Building Blocks, see task scheduler details: https://software.intel.com/en-us/node/506294
  and architecture of the library from https://techdecoded.intel.io/big-picture/adventures-in-threading-how-tbb-is-advancing-parallelism/#gs.p062y9
  ![](./media/TBB_Functions.png)

- Extending Intel OpenMP with libkomp + multicore-myltiGPU scheduling:
  https://calcul.math.cnrs.fr/attachments/spip/Documents/Journees/janv2017/kaapi_libkomp.pdf

- OpenMP runtime's: GNU's libGOMP, Intel's libOMP, Inria's libkomp, Inria's XKaapi

  https://hal.archives-ouvertes.fr/hal-01666343/file/wamca2017.pdf

- Phylanx: Distributed Array Processing on top of HPX

  https://github.com/STEllAR-GROUP/phylanx

  http://stellar.cct.lsu.edu/pubs/wei_riken_2019_phylanx_poster.pdf

- HPX: Higher-level Parallelization in C++ for Asynchronous
Task-Based Programming

  https://calcul.math.cnrs.fr/attachments/spip/Documents/Journees/janv2017/parallelism_in_cpp_sc15.pdf

  https://github.com/STEllAR-GROUP/hpx

  http://stellar.cct.lsu.edu/pubs/pgas14.pdf

  https://indico.cern.ch/event/513104/contributions/2035127/attachments/1275186/1891535/Diving_into_Parallelization_in_Modern_C_using_HPX_-_Unleashing_the_full_power.pdf

- OpenMP implemented on top of HPX

  https://arxiv.org/abs/1903.03023

  https://github.com/STEllAR-GROUP/hpxMP

- Adobe's Stlib, concurrency/parallelism for image editing primitives: https://github.com/stlab/libraries/tree/develop/stlab/concurrency
- Sean Parent (Adobe)'s presentation "Better Code: COncurrency" on how to build a task system: https://youtu.be/zULU6Hhp42w?t=1695

- Libdispatch / Grand Central Dispatch: https://github.com/apple/swift-corelibs-libdispatch

- Grand Central Dispatch Internals: http://newosxbook.com/articles/GCD.html

- Rust's Rayon
  - https://github.com/rayon-rs/rayon/blob/master/FAQ.md
  - https://www.youtube.com/watch?v=gof_OEv71Aw

- Halide runtime:
  - https://github.com/halide/Halide/blob/master/src/runtime/posix_threads.cpp
  - https://github.com/halide/Halide/blob/master/src/runtime/runtime_api.cpp
  - https://github.com/halide/Halide/blob/master/src/runtime/thread_pool_common.h

- Cpp Taskflow: Fast Task-based Parallel Programming using Modern C++. (with DNN examples vs OpenMP and TBB)

  https://github.com/cpp-taskflow/cpp-taskflow

  https://tsung-wei-huang.github.io/talk/ipdps19-presentation.pdf

  https://tsung-wei-huang.github.io/papers/ipdps19.pdf

  https://woset-workshop.github.io/PDFs/a3.pdf

- Transwarp: header-only task scheduling via a DAG of tasks, https://github.com/bloomen/transwarp

- Staccatto: Work-Stealing Task Scheduler, https://github.com/rkuchumov/staccato


- Cilk: https://www.usenix.org/legacy/publications/library/proceedings/ana97/full_papers/blumofe/blumofe_html/node2.html

### Heterogeneous arch scheduling

- Kokkos: Performance portability ecosystem

  with HBM memory, Cuda UVM and AMD ROCm support

  https://github.com/kokkos/kokkos

  https://cfwebprod.sandia.gov/cfdocs/CompResearch/docs/Trott-white-paper.pdf

  https://www.osti.gov/servlets/purl/1457941

- Programming modern HPC platforms

  Scalability study with 1152 cores + 288 GPUs

  https://calcul.math.cnrs.fr/attachments/spip/Documents/Journees/janv2017/tasks_programming_and_starpu.pdf

- StarPU: A Unified Runtime System for Heterogeneous Multicore Architectures, http://starpu.gforge.inria.fr

- High performance scheduling of mixed-mode DAGs on heterogeneous multicores, 2019

  https://arxiv.org/pdf/1901.05907.pdf

- Xkaapi OpenMP runtime: http://kaapi.gforge.inria.fr/#!index.md

- Kstar OpenMP compiler: http://kstar.gforge.inria.fr/#!index.md

- XKaapi: A Runtime System for Data-Flow Task
  Programming on Heterogeneous Architectures, 2013

  https://hal.inria.fr/hal-00799904/document
