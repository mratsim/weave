# Changelog

### v0.x.x - Unreleased

### v0.3.0 - January 2020

`sync(Weave)` has been renamed `syncRoot(Weave)` to highlight that it is only valid on the root task in the main thread. In particular, a procedure that uses syncRoot should not be called be in a multithreaded section. This is a breaking change. In the future such changes will have a deprecation path but the library is only 2 weeks old at the moment.

`parallelFor`, `parallelForStrided`, `parallelForStaged`, `parallelForStagedStrided`
now support an "awaitable" statement to allow fine-grain sync.

Fine-grained data-dependencies are under research (for example launch a task when the first 50 iterations are done out of a 100 iteration loops), "awaitable" may change
to have an unified syntax for delayed tasks depending on a task, a whole loop or a subset of it.
If possible, it is recommended to use "awaitable" instead of `syncRoot()` to allow composable parallelism, `syncRoot()` can only be called in a serial section of the code.

Weave can now be compiled with Microsoft Visual Studio in C++ mode.

"LastVictim" and "LastThief" WV_Target policy has been added.
The default is still "Random", pass "-d:WV_Target=LastVictim" to explore performance on your workload

"StealEarly" has been implemented, the default is not to steal early,
pass "-d:WV_StealEarly=2" for example to allow workers to initiate a steal request
when 2 tasks or less are left in their queue.

#### Performance

Weave has been thoroughly tested and tuned on state-of-the-art matrix multiplication implementation
against competing pure Assembly, hand-tuned BLAS implementations to reach High-performance Computing scalability standards.

3 cases can trigger loop splitting in Weave:
- loadBalance(Weave),
- sharing work to idle child threads
- incoming thieves
The first 2 were not working properly and resulted in pathological performance cases.
This has been fixed.

Fixed strided loop iteration rounding
Fixed compilation with metrics

Executing a loop now counts as a single task for the adaptative steal policy.
This prevents short loops from hindering steal-half strategy as it depends
on the number of tasks executed per steal requests interval.

#### Internals
- Weave uses explicit finite state machines in several places.
- The memory pool now has the same interface has malloc/free, in the past
  freeing a block required passing a threadID as this avoided an expensive getThreadID syscall.
  The new solution uses assembly code to get the address of the current thread thread-local storage
  as an unique threadID.
- Weave memory subsystem now supports LLVM AddressSanitizer to detect memory bugs.
  Spurious (?) errors from Nim and Weave were not removed and are left as a future task.

### v0.2.0 - December 2019

Weave `EventNotifier` has been rewritten and formally verified.
Combined with using raw Linux futex to workaround a condition variable bug
in glibc and musl, Weave backoff system is now deadlock-free.

Backoff has been renamed from `WV_EnableBackoff` to `WV_Backoff`.
It is now enabled by default.

Weave now supports Windows.

### v0.1.0 - December 2019

Initial release
