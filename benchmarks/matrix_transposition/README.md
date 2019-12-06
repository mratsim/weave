# Matrix transposition

This benchmark extract from [Laser](https://github.com/numforge/laser)
stresses the ability for a runtime to support nested loops.

A matrix is being copied to another buffer with transposition.
For one buffer or the other the accesses will not be linear
so it is important to do tiling. As dimensions might be skewed,
the ideal tiling should be 2D with nested parallel for loops that properly find
work for all cores even if a matrix is tall and skinny or short and fat.

Note that as OpenMP nested loop support is very problematic
we use the `collapse` clause for OpenMP which is only usable
in a restricted number of scenarios.
