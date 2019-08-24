# Benchmarks versus State-of-the-Art Matrix Multiplication.

This evaluates threading performance versus state-of-the-art
implementation of matrix multiplication.

Those implementations commonly known as GEMM (GEneralied Matrix Multiplication)
are part of a BLAS library, BLAS being a standard interface for vector and matrices linear algebra.

Common implementations include:
- OpenBLAS (Assembly)
- Intel MKL (Assembly)
- Apple Accelerate
- BLIS
- ARM Performance library

which are highly-tuned to use CPU L1 and L2, prefetching
SIMD vectorizations and core parallelism.

Memory locality has a significant impact on performance
and threading frameworks should minimize cache misses and memory footprint.

Note that the common naive benchmarking of matrix multiplication
with triple for-loop can be 100x times slower than optimized implementation
on decently sized matrices. This performance gap grows at N^3 rate, asuming
we multiply two NxN matrices.

[Laser](https://github.com/numforge/laser) implements a state-of-the-art
GEMM that reaches performance similar to OpenBLAS in pure Nim and parallelism
is obtained through OpenMP.

We reuse Laser implementation and switch the backend to Weave's scheduler
to measure overhead on high-performance computing workload.

Laser code as of Aug. 24, 2019 (https://github.com/numforge/laser/tree/af191c086b4a98c49049ecf18f5519dc6856cc77)

`laser_gemm_backend` contains backend routines with no parallelism.

`laser_utils` contains routines that are used across all Laser primitives
