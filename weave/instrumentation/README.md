# Instrumentation

Picasso aims to be a robust, maintainable and efficient multithreading runtime.

As such the code should be instrumented to help runtime behavior analysis, debugging, performance profiling and quality assurance in general.

## Requirements of instrumentation tools.

_Observations will affect reality_

While the runtime should be stable under a variety of dynamic load conditions unfortunately any kind of instrumentation added to it will have impact on its characteristics and what is being measured.

Here are requirements of the instrumentation tools
- For obvious reasons, any instrumentation must be thread-safe.
- If there is an output to console or to file, the worker thread responsible must be identified and the "dump" side effect must be atomic.
  For example assuming 2 threads output "Thread #1: Hello World!" and "Thread #2: Hello World!"
  The following is not acceptable:
  ```
  TThhrreeaadd #1121:: HHello loW Woorlld!
  d!
  ```

Here are strong recommendations:
- If the tooling requires to allocate memory it is strongly recommended to
  use stack allocation or a memory pool. Using heap allocation in a
  multithreaded context will cause heavy stress on memory allocators.
- For strings, const string are optimized to not use the heap.
  They can be used together with c_printf for logging without allocation

## Format

Output should be given in an easy to parse format with common CLI tools like `awk`. The aim is to allow investigation with just a `ssh` connection to a device or server with limited tools and/or memory.

## External tools

Internal tools are complemented by a breadth of external tools for various purposes, hopefully documentation or scripts will be added to support them as most allow to analyze the library from another angle:

- [ ] topology: hyperthreading siblings, NUMA
- [ ] measuring performance, core usage, latencies, cache misses, view assembly:
    - `perf`
    - Intel VTune
    - Apple Instruments
- [ ] [bloaty](https://github.com/google/bloaty) for binary size
- [ ] [`perf c2c`](https://joemario.github.io/blog/2016/09/01/c2c-blog/) for measuring cache contention / false sharing
- [ ] [helgrind](http://valgrind.org/docs/manual/hg-manual.html) for locking

Requires changing the internals:
- [ ] [coz](https://github.com/plasma-umass/coz) for causal profiling and bottleneck detection
- [ ] [relacy](https://github.com/dvyukov/relacy) for race detection
