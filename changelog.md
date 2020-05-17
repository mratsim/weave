# Changelog

### v0.x.x - Unreleased

#### Breaking

- The experimental `Pledge` for dataflow parallelism have been renamed
  `FlowEvent` to be in line with:
  - `AsyncEvent` in Nim async frameworks
  - `cudaEvent_t` in CUDA
  - `cl_event` in OpenCL

  Renaming changes:
  - `newPledge()` becomes `newFlowEvent()`
  - `fulfill()` becomes `trigger()`
  - `spawnDelayed()` becomes `spawnOnEvents()`
  - The `dependsOn` clause in `parallelFor` becomes `dependsOnEvent`

#### Features

- Added `isReady(Flowvar)` which will return true is `sync` would block on that Flowvar or if the result is actually immediately available.
- `syncScope:` to block until all tasks and their (recursive)
  descendants are completed.
- Dataflow parallelism can now be used with the C++ target.
- Weave as a background service (experimental).
  Weave can now be started on a dedicated thread
  and handle **jobs** from any thread.
  To do this, Weave can be started with `thr.runInBackground(Weave)`.
  Job providing threads should call `setupSubmitterThread(Weave)`,
  and can now use `submit function(args...)` and `waitFor(PendingResult)`
  to have Weave work as a job system.
  Jobs are handled in FIFO order.
  Within a job, tasks can be spawned.

### v0.4.0 - April 2020 - "Bespoke"

#### Compatibility

Weave now targets Nim 1.2.0 instead of `devel`. This is the first Nim release
that supports all requirements of Weave.

#### Features

Weave now provides an experimental "dataflow parallelism" mode.
Dataflow parallelism is also known under the following names:
- Graph parallelism
- Stream parallelism
- Pipeline parallelism
- Data-driven parallelism

Concretely this allows delaying tasks until a condition is met.
This condition is called `Pledge`.
Programs can now create a "computation graph"
or a pipeline of tasks ahead of time that depends on one or more `Pledge`.

For example a game engine might want to associate a pipeline of transformations
to each frame and once the frame prerequisites are met, set the `Pledge` to `fulfilled`.

The `Pledge` can be combined with parallel loops and programs can wait on specific
iterations or even iteration ranges for example to implement parallel video processing
as soon as a subset of the frame is ready instead of waiting for the whole frame.
This exposes significantly more parallelism opportunities.

Dataflow parallelism cannot be used with the C++ backend at the moment.

Weave now provides the 3 main parallelism models:
- Task Parallelism (spawn/sync)
- Data Parallelism (parallel for loop)
- Dataflow Parallelism (delayed tasks)

#### Performance

Weave scalability has been carefully measured and improved.

On matrix multiplication, the traditional benchmark to classify the top 500 supercomputers of the world, Weave speedup on an 18-core CPU is 17.5x while the state-of-the-art Intel implementation using OpenMP allows 15.5x-16x speedup.

### v0.3.0 - January 2020 - "Beam me up!"

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

### v0.2.0 - December 2019 - "Overture"

Weave `EventNotifier` has been rewritten and formally verified.
Combined with using raw Linux futex to workaround a condition variable bug
in glibc and musl, Weave backoff system is now deadlock-free.

Backoff has been renamed from `WV_EnableBackoff` to `WV_Backoff`.
It is now enabled by default.

Weave now supports Windows.

### v0.1.0 - December 2019 - "Arabesques"

Initial release
