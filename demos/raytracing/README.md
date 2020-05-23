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

### Setup

CPU: i9-9980XE, 18 cores, overclocked at 4.1GHz all-core turbo (from 3.0 nominal)
The code was compiled with default flag, hence x86-64, hence SSE2.

- Nim devel (1.3.5 2020-05-16) + GCC v10.1.0
  - `nim c --threads:off -d:danger`
  - `nim c --threads:on -d:danger`
- GCC v10.1.0
  - `-O3`
  - `-O3 -fopenmp`
- GCC v8.4.0
  - `-O3`
  - `-O3 -fopenmp`
- Clang v10.0.0
  - `-O3`
  - `-O3 -fopenmp`

### Commands


```bash
git clone https://github.com/mratsim/weave
cd weave
nimble install -y # install Weave dependencies, here synthesis, overwriting if asked.

nim -v # Ensure you have nim 1.2.0 or more recent

# Threads on (by default in this repo)
nim c -d:danger -o:build/ray_threaded demos/raytracing/smallpt.nim

# Threads off
nim c -d:danger --threads:off -o:build/ray_single demos/raytracing/smallpt.nim

g++ -O3 -o build/ray_gcc_single demos/raytracing/smallpt.cpp
g++ -O3 -fopenmp -o build/ray_gcc_omp demos/raytracing/smallpt.cpp

clang++ -O3 -o build/ray_clang_single demos/raytracing/smallpt.cpp
clang++ -O3 -fopenmp -o build/ray_clang_omp demos/raytracing/smallpt.cpp
```

Then run for 300 samples with

```
build/ray_threaded 300
# ...
build/ray_clang_omp 300
```

### Results & Analysis

GCC 10 has a significant OpenMP regression

|      Bench       |     Nim     | Clang C++ OpenMP | GCC 10 C++ OpenMP | GCC 8 C++ OpenMP |
| ---------------- | ----------: | ---------------: | ----------------: | ---------------: |
| Single-threaded  | 4min43.369s |        4m51.052s |       4min50.934s |        4m50.648s |
| Multithreaded    |     12.977s |          14.428s |       2min14.616s |          12.244s |
| Nested-parallel  |     12.981s |                  |                   |                  |
| Parallel speedup |      21.83x |           20.17x |             2.16x |           23.74x |

Single-threaded Nim is 2.7% faster than Clang C++.
Multithreaded Nim via Weave is 11.1% faster Clang C++.

GCC 8 despite a simpler OpenMP design (usage of a global task queue instead of work-stealing)
achieves a better speedup than both Weave and Clang.
In that case, I expect it's because the tasks are so big that there is minimal contention
on the task queue, furthermore the OpenMP schedule is "Dynamic" so we avoid the worst case scenario
with static scheduling where a bunch of threads are assigned easy rays that never collide with a surface
and a couple of threads are drowned in complex rays.

I have absolutely no idea of what happened to OpenMP in GCC 10.

Note: I only have 18 cores but we observe speedups in the 20x
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

Kevin Beason code is licensed under (mail redacted to avoid spam)

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
