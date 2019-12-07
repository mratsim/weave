# Pure Nim GEMM

This is a pure Nim implementation of a GEMM kernel (GEneralized Matrix Multiplication).

The code is taken from [Laser](https://github.com/numforge/laser)

This kernel follows state-of-the-art loop tiling, register blocking, SIMD vectorization and code generation techniques to reach the performance
of pure Assembly libraries like OpenBLAS or MKL with only generic code that is easily portable to new platform like ARM, RISCv5 or MIPS and to new types like integers.

GEMM is what is used to rank the top 500 Supercomputer of the world.
It is one of the rare workloads that is able to exercise 100% of the CPU compute.
Most over workloads are actually memory-bound.
