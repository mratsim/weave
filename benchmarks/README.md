# Weave Parallel Benchmark Suite

This folder stresses multiple aspects of the Weave runtime to ensure its suitable for a wide variety of workload.

Here is a table of the available benchmarks:

| Name                                                          | Parallelism             | Notable for stressing               | Origin                                     |
|---------------------------------------------------------------|-------------------------|-------------------------------------|--------------------------------------------|
| Black & Scholes Option Pricing (Finance)                      | Data parallelism        |                                     |                                            |
| DFS (Depth-First Search)                                      | Task Parallelism        | Scheduler Overhead                  | Staccato                                   |
| Fibonacci                                                     | Task Parallelism        | Scheduler Overhead                  | Cilk                                       |
| Heat diffusion (Stencil / Jacobi-iteration - Cache-Oblivious) | Task Parallelism        |                                     | Cilk                                       |
| Matrix Multiplication (Cache-Oblivious)                       | Task Parallelism        |                                     | Cilk                                       |
| Matrix Transposition                                          | Nested Data Parallelism | Nested loop                         | [Laser](https://github.com/numforge/laser) |
| Nqueens                                                       | Task Parallelism        | Speculative/Conditional parallelism | Cilk                                       |
| SPC (Single Task Producer)                                    | Task Parallelism        | Load Balancing                      | Tasking 2.0 (A. Prell Thesis)              |

Planned benchmarks

| Name                               | Parallelism             | Notable for stressing               | Origin                                                                               |
|------------------------------------|-------------------------|-------------------------------------|--------------------------------------------------------------------------------------|
| BPC (Bouncing producer-Consumer)   | Task Parallelism        | Load Balancing                      | Dinan et al / Tasking 2.0 (A. Prell Thesis)                                          |
| Generic Parallel For               | Data Parallelism        | Load Balancing                      | [OpenMP benchmark for PyTorch](https://github.com/zy97140/omp-benchmark-for-pytorch) |
| Unbalanced Tree Search             | Task Parallelism        | Load balancing                      | UTS paper / Barcelona OMP Task Suite                                                 |
| Matrix Multiplication (GEMM, BLAS) | Nested Data Parallelism | Compute, Memory, SIMD Vectorization | BLAS, Linpack                                                                        |
