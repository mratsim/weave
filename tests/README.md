# Testing

Tests are done at the end of Weave files in an `when isMainModule` block
and also by running the benchmarks and ensuring:
- no deadlocks or livelocks
- ensuring correct result

## Debugging tools

Weave has intentionally a very restricted set of cross-thread synchronization data structures.
Data races can only appear in them, those are the `cross_thread_com` folder and includes:
- 3 kinds of channels to transfer tasks, steal requests, and result (==Future) between threads
- An event notifier to wake up sleeping threads (formally verified! which also uncovered a deadlock bug in glibc)
- Pledges (~Promises that can have delayed tasks triggered on fulfillment)
- Scoped barriers (to await all tasks and descendant tasks in a scope)

Some useful commands

### LLVM ThreadSanitizer

https://clang.llvm.org/docs/ThreadSanitizer.html

```
nim c -r -d:danger --passC:"-fsanitize=thread" --passL:"-fsanitize=thread" --debugger:native --cc:clang --outdir:build weave/cross_thread_com/channels_spsc_single_ptr.nim
```

### Valgrind Helgrind

https://valgrind.org/docs/manual/hg-manual.html

```
nim c -r -d:danger --debugger:native --cc:clang --outdir:build weave/cross_thread_com/channels_spsc_single_ptr.nim
valgrind --tool=helgrind build/channels_spsc_single_ptr
```

### Valgrind Data Race Detection

https://valgrind.org/docs/manual/drd-manual.html

```
nim c -r -d:danger --debugger:native --cc:clang --outdir:build weave/cross_thread_com/channels_spsc_single_ptr.nim
valgrind --tool=drd build/channels_spsc_single_ptr
```

## Formal verification

Formal verification is the most powerful tool to prove that an concurrent data structure or a synchronization primitive has a sound design.
An example using TLA (Temporal logic of Action) is available in the formal_verification folder.

See Leslie Lamport page on TLA, usage and use-cases: https://lamport.azurewebsites.net/tla/tla.html

However while proving design is sound is great, we also need to prove that the implementation is bug-free.
This needs a model-checking tool that is aware of C11/C++11 memory model (i.e. relaxed, acquire, release) atomics and fences.

This is planned.

## Research

Research into data race detection, sanitiziers, model checking and formal verification for concurrency
is gathered here: https://github.com/mratsim/weave/issues/18
