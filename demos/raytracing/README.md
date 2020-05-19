# Raytracing

This is a port to Nim and Weave of
SmallPT by Kevin Beason https://www.kevinbeason.com/smallpt/

The original C++ version is also provided (with 4 extra lines to highlight original code quirks when porting).

## Showcase

The Nim version has can use a single parallel-for loop
or nested parallel-for loop for better load balancing (important when the inner loop .is actually larget than the outer loop)

At the moment, there is no random number generator that can deal with
the dynamic thread migration of Weave so we get interesting artifacts
compared to the single-threaded or the single parallel-for versions.

**Single-thread or single parallel-for**

![ray_trace_300samples_nim_threaded](ray_trace_300samples_nim_threaded.png)

**Nested parallel-for**

![ray_trace_300samples_nim_nested](ray_trace_300samples_nim_nested.png)

## Benchmark

Note: except for the nested parallelism which has RNG issue,
the Nim and C++ versions are pixel equivalent.

- Nim devel (1.3.5 2020-05-16) + GCC v10.1.0
  - `nim c --threads:off -d:danger`
  - `nim c --threads:on -d:danger`
- GCC v10.1.0
  - `-03`
  - `-O3 -fopenmp`
- Clang v10.0.0
  - `-03`
  - `-O3 -fopenmp`

| Bench            | Nim         | Clang C++ | GCC C++     |
|------------------|-------------|-----------|-------------|
| Single-threaded  | 4min43.369s | 4m51.052s | 4min50.934s |
| Multithreaded    | 0min13.211s | 14.428s   | 2min14.616s |
| Nested-parallel  | 0min12.981s |           |             |
| Parallel speedup | 21.83x      | 20.17x    | 2.16x       |

Single-threaded Nim is 2.7% faster than Clang C++
Multithreaded Nim via Weave is 11.1% faster Clang C++

Note: I only have 18 cores but we observe over 18x speedup
with Weave and LLVM. This is probably due to 2 factors:
- Raytracing is pure compute, in particular contrary to high-performance computing
  and machine learning workloads which are also very memory-intensive (matrices and tensors with thousands to millions of elements)
  The scene has only 10 objects and a camera to keep track off.
  Memory is extremely slow, you can do 100 additions while waiting for data
  in the L2 cache.
- A CPU has a certain number of execution ports and can use instruction-level parallelism (we call that superscalar). Hyperthreading is a way to
  use those extra execution ports. However in many computing workloads
  the sibling cores are also competing for memory bandwidth.
  From the previous point, this is not true for raytracing
  and so we enjoy super linear speedup.

## License

Kevin beason code is licensed under (mail redacted to avoid spam)

```
LICENSE

Copyright (c) 2006-2008 Kevin Beason (<surname>.<name>@gmail.com)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```
