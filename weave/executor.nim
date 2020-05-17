# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Executor
# ----------------------------------------------
#
# Weave can be used in "Executor-mode".
# In that case jobs are submitted from threads that are foreign to Weave
#
# The hard part is combining all the following:
# - Ensuring that the worker that receive the new job is awake.
# - Ensure no race condition with awakening and termination detection.
# - Limiting contention due to all workers writing to the same data structure.
# - Limiting latency between scheduling and running the job.
# - Greedy scheduler: as long as there is enough work, no worker is idle.
#
#
# 1. Weave termination detection is distributed, based on combining-tree
#    or what is called "Lifeline-based Global Load Balancing"
#    - http://www.cs.columbia.edu/~martha/courses/4130/au12/p201-saraswat.pdf
#    i.e. each worker has a parent and a parent cannot sleep before its children.
#    This means that submitting job to a random Worker in the threadpool
#    requires ensuring that the Worker is awake to avoid termination detection.
#
# 2. A global job queue will always have job distributed to awake workers.
#    It also ensures minimum latency.
#    But the queue becomes a contention and scalability bottleneck.
#    Also lock-free intrusive MPMC queues are very hard to write.
#
# 3. We choose to create a ManagerContext which is in charge of
#    distributing incoming jobs.
#    The manager is the root thread, it is always awake on job submission via an EventNotifier
#    The main issue is latency to distribute the jobs if the root thread is
#    on a long-running task with few loadBalancing occasions
#    but this already existed before the executor mode
#    when all tasks where created on Weave's root thread.
#
# The ManagerContext can be extended further to support distributed computing
# with Weave instances on muliple nodes of a cluster.
# The manager thread can become a dedicated separate thread
# if communication costs and jobs latnecy are high enough to justify it in the future.

import
  # Standard library
  macros, typetraits, atomics, os,
  # Internal
  ./memory/[allocs, memory_pools],
  ./contexts, ./config, ./runtime,
  ./datatypes/[sync_types, context_thread_local],
  ./instrumentation/[contracts, loggers],
  ./cross_thread_com/[event_notifiers, channels_mpsc_unbounded_batch],
  ./state_machines/sync_root

{.push gcsafe, inline.} # TODO raises: []

proc waitUntilReady*(_: typedesc[Weave]) =
  ## Wait until Weave is ready to accept jobs
  ## This blocks the thread until the Weave runtime (on another thread) is fully initialized
  # We use a simple exponential backoff for waiting.
  var backoff = 1
  while not globalCtx.manager.acceptsJobs.load(moRelaxed):
    sleep(backoff)
    backoff *= 2
    if backoff > 16:
      backoff = 16

proc setupSubmitterThread*(_: typedesc[Weave]) =
  ## Configure a thread so that it can submit jobs to the Weave runtime.
  ## This is useful if we want Weave to work
  ## as an independent "service" or "execution engine"
  ## and still being able to offload computation
  ## to it instead of mixing
  ## logic or IO and Weave on the main thread.
  ##
  ## This will block until Weave is ready to accet jobs
  preCondition: localThreadKind == Unknown

  jobProviderContext.mempool = wv_alloc(TLPoolAllocator)
  jobProviderContext.mempool[].initialize()

  localThreadKind = SubmitterThread

proc teardownSubmitterThread*(_: typedesc[Weave]) =
  ## Maintenance before exiting a job submitter thread

  # TODO: Have the main thread takeover the mempool if it couldn't be fully released
  let fullyReleased {.used.} = jobProviderContext.mempool.teardown()
  localThreadKind = Unknown

proc processAllandTryPark*(_: typedesc[Weave]) =
  ## Process all tasks and then try parking the weave runtime
  ## This `syncRoot` then put the Weave runtime to sleep
  ## if no job submission was received concurrently
  ##
  ## This should be used if Weave root thread (that called init(Weave))
  ## is on a dedicated long-running thread
  ## in an event loop:
  ##
  ## while true:
  ##   park(Weave)
  ##
  ## New job submissions will automatically wakeup the runtime

  manager.jobNotifier[].prepareToPark()
  syncRoot(Weave)
  debugTermination: log("Parking Weave runtime\n")
  manager.jobNotifier[].park()
  debugTermination: log("Waking Weave runtime\n")

proc wakeup(_: typedesc[Weave]) =
  ## Wakeup the runtime manager if asleep
  Backoff:
    manager.jobNotifier[].notify()

proc runForever*(_: typedesc[Weave]) =
  ## Start a never-ending event loop on the current thread
  ## that wakes-up on job submission, handles multithreaded load balancing,
  ## help process tasks
  ## and spin down when there is no work anymore.
  while true:
    processAllandTryPark(Weave)

# TODO: "not nil"
proc runUntil*(_: typedesc[Weave], signal: ptr Atomic[bool]) =
  ## Start a Weave event loop until signal is true on the current thread.
  ## It wakes-up on job submission, handles multithreaded load balancing,
  ## help process tasks
  ## and spin down when there is no work anymore.
  preCondition: not signal.isNil
  while not signal[].load(moRelaxed):
    processAllandTryPark(Weave)
  syncRoot(Weave)

proc runInBackground*(
       thr: var Thread[ptr Atomic[bool]],
       _: typedesc[Weave],
       signalShutdown: ptr Atomic[bool]
     )  =
  ## Start the Weave runtime on a background thread.
  ## It wakes-up on job submissions, handles multithreaded load balancing,
  ## help process tasks
  ## and spin down when there is no work anymore.
  proc eventLoop(shutdown: ptr Atomic[bool]) {.thread.} =
    init(Weave)
    Weave.runUntil(shutdown)
    exit(Weave)
  {.gcsafe.}: # Workaround regression - https://github.com/nim-lang/Nim/issues/14370
    thr.createThread(eventLoop, signalShutdown)

proc runInBackground*(thr: var Thread[void], _: typedesc[Weave])  =
  ## Start the Weave runtime on a background thread.
  ## It wakes-up on job submissions, handles multithreaded load balancing,
  ## help process tasks
  ## and spin down when there is no work anymore.
  proc eventLoop() {.thread.} =
    init(Weave)
    Weave.runForever()
  {.gcsafe.}: # Workaround regression - https://github.com/nim-lang/Nim/issues/14370
    thr.createThread(eventLoop)

proc submitJob*(job: sink Job) =
  ## Submit a serialized job to a worker at random
  preCondition: not jobProviderContext.mempool.isNil
  preCondition: globalCtx.manager.acceptsJobs.load(moRelaxed)

  let sent {.used.} = managerJobQueue.trySend job
  wakeup(Weave)
  debugTermination:
    log("Thread %d: sent job to Weave runtime and woke it up.\n", getThreadID())
  postCondition: sent
