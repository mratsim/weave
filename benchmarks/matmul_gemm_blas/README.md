# GEneralized Matrix Multiplication (GEMM)

GEneralized Matrix Multiplication (GEMM) are part of BLAS libraries (for Basic Linear Algebra Subroutines).
GEMMs implementations are the state-of-the-art implementations of matrix multiplication.

Most GEMMs implementations are more than 80% pure Assembly code. They use advanced tiling and prefetching techniques
to ensure that what is in registers, L1 cache, L2 cache and addressable via the TLB (Translation Lookaside Buffer)
is what will be needed next.
In summary, to use a CPU compute at 100% you need to first solve the following issues:
- Memory bandwidth: accessing data from RAM is too slow
- Cache reuse: Accessing data from L1 cache ~100 cycles is too slow
               This requires proper use of prefetching
- TLB miss: Accessing data from another memory page is too slow
- Instruction-level parallelism: SIMD loads and stores should be interleaved to hide Fused-Multiple-Add latency of a couple cycles
- Register limitations: x86-64 only has 16 general purposes registers that can hold the matrices rows/cols indices
- Hyperthreading: sibling thread will compete for L1 cache and might flush the other prefetched data

On top of that, a multithreading runtime such as Weave also as a non-trivial footprint:
- Compete in L1 cache
- Allocates memory and has its own memory manager so increased chance of TLB misses
- Prefetch might be rendered useless if there is a context switch to Weave after.

GEMM is how the top 500 SuperComputers of the world are ranked (via LINPACK).
The main issue with OpenMP-based GEMM is that it is not composable
as OpenMP does not properly support nested parallelism and many algorithms
especially in deep learning would benefits from launch multiple GEMMs
on batches of matrices or as parallel subtree of a computation graph.

Note that most matrix multiplication in other multithreading benchmark runtime
are actually memory-bandwidth bound and any measure of parallelism is flawed.
On my machine, for a matrix multiplication of 1920x1920 matrices,
a naive triple-for loop would reach 2GFlop/s single-threaded
while industry-grade Intel-MKL reaches over 200GFlop/s single threaded,
with the speed difference growing in n^3 rate with the size of the matrices.
