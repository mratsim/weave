# Histogram 2D

This is a very interesting benchmark to test map-reduce style of computation and nested parallelism.

It needs:
- 2 loops over a 2D matrix
- A reduction

OpenMP is unable to deal intuitively with nesting
2 parallel loops and a custom reduction operation
