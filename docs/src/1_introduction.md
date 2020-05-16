# Weave, a state-of-the-art multithreading runtime

_"Good artists borrow, great artists steal."_ -- Pablo Picasso

Weave (codenamed "Project Picasso") is a multithreading runtime for the [Nim programming language](https://nim-lang.org/).

It is continuously tested on Linux, MacOS and Windows for the following CPU architectures: x86, x86_64 and ARM64 with the C and C++ backends.

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
