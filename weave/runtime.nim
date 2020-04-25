# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  os, cpuinfo, strutils,
  # Internal
  ./instrumentation/[contracts, profilers, loggers],
  ./contexts, ./config,
  ./datatypes/[sync_types, prell_deques, binary_worker_trees],
  ./cross_thread_com/[channels_spsc_single_ptr, channels_mpsc_unbounded_batch],
  ./memory/[persistacks, lookaside_lists, allocs, memory_pools],
  ./scheduler, ./victims, ./signals,
  ./state_machines/sync_root,
  # Low-level primitives
  ./primitives/barriers

when defined(windows):
  import ./primitives/affinity_windows
else:
  import ./primitives/affinity_posix

# Runtime public routines
# ----------------------------------------------------------------------------------

proc init*(_: type Weave) =
  # TODO detect Hyper-Threading and NUMA domain

  if existsEnv"WEAVE_NUM_THREADS":
    workforce() = getEnv"WEAVE_NUM_THREADS".parseInt.int32
    if workforce() <= 0:
      raise newException(ValueError, "WEAVE_NUM_THREADS must be > 0")
    elif workforce() > WV_MaxWorkers:
      echo "WEAVE_NUM_THREADS truncated to ", WV_MaxWorkers, " (WV_MaxWorkers)"
  else:
    workforce() = int32 countProcessors()

  ## Allocation of the global context.
  globalCtx.mempools = wv_alloc(TLPoolAllocator, workforce())
  globalCtx.threadpool = wv_alloc(Thread[WorkerID], workforce())
  globalCtx.com.thefts = wv_alloc(ChannelMpscUnboundedBatch[StealRequest], workforce())
  globalCtx.com.tasks = wv_alloc(Persistack[WV_MaxConcurrentStealPerWorker, ChannelSpscSinglePtr[Task]], workforce())
  Backoff:
    globalCtx.com.parking = wv_alloc(EventNotifier, workforce())
  globalCtx.barrier.init(workforce())

  # Lead thread - pinned to CPU 0
  myID() = 0
  when not(defined(cpp) and defined(vcc)):
    # TODO: Nim casts between Windows Handles but that requires reinterpret cast for C++
    pinToCpu(0)

  # Create workforce() - 1 worker threads
  for i in 1 ..< workforce():
    createThread(globalCtx.threadpool[i], worker_entry_fn, WorkerID(i))
    # TODO: we might want to take into account Hyper-Threading (HT)
    #       and allow spawning tasks and pinning to cores that are not HT-siblings.
    #       This is important for memory-bound workloads (like copy, addition, ...)
    #       where both sibling cores will compete for L1 and L2 cache, effectively
    #       halving the memory bandwidth or worse, flushing what the other put in cache.
    #       Note that while 2x siblings is common, Xeon Phi has 4x Hyper-Threading.
    when not(defined(cpp) and defined(vcc)):
      # TODO: Nim casts between Windows Handles but that requires reinterpret cast for C++
      pinToCpu(globalCtx.threadpool[i], i)

  myMemPool().initialize()

  # Root task
  myWorker().currentTask = newTaskFromCache()
  myTask().parent = nil
  myTask().fn = cast[type myTask().fn](0xEFFACED)
  myTask().scopedBarrier = nil

  init(localCtx)
  # Wait for the child threads
  discard globalCtx.barrier.wait()

proc loadBalance*(_: type Weave) {.gcsafe.} =
  ## This makes the current thread ensures it shares work with other threads.
  ##
  ## This is done automatically at synchronization points
  ## like task spawn and sync. But for long-running unbalance tasks
  ## with no synchronization point this is needed.
  ##
  ## For example this can be placed at the end of a for-loop.
  #
  # Design notes:
  # this is a leaky abstraction of Weave design, busy workers
  # are the ones distributing tasks. However in the IO world
  # adding poll() calls is widely used as well.
  #
  # It's arguably a much better way of handling:
  # - load imbalance
  # - the wide range of user CPUs
  # - dynamic environment changes (maybe there are other programs)
  # - generic functions on collections like map
  #
  # than and asking the developer to guesstimate the task size and
  # hardcoding the task granularity like some popular frameworks requires.
  #
  # See: PyTorch troubles with OpenMP
  #      Should we use OpenMP when we have 1000 or 80000 items an array?
  #      https://github.com/zy97140/omp-benchmark-for-pytorch
  #      It depends on:
  #      - is it on a dual core CPU
  #      - or a 4 sockets 100+ cores server grade CPU
  #      - are you doing addition
  #      - or exponentiation

  shareWork()

  # Check also channels on behalf of the children workers that are managed.
  if myThieves().peek() != 0 or
      myWorker().leftIsWaiting and hasThievesProxy(myWorker().left) or
      myWorker().rightIsWaiting and hasThievesProxy(myWorker().right):
    var req: StealRequest
    while recv(req):
      discard distributeWork(req, workSharing = false)

proc getThreadId*(_: type Weave): int {.inline.} =
  ## Returns the Weave ID of the current executing thread
  ## ID is in the range 0 ..< WEAVE_NUM_THREADS
  ## With 0 being the lead thread and WEAVE_NUM_THREADS = min(countProcessors, getEnv"WEAVE_NUM_THREADS")
  myID().int

proc getNumThreads*(_: type Weave): int {.inline.} =
  ## Returns the number of threads available in Weave threadpool
  workforce().int

proc globalCleanup() =
  for i in 1 ..< workforce():
    joinThread(globalCtx.threadpool[i])

  globalCtx.barrier.delete()
  wv_free(globalCtx.threadpool)

  # Channels, each thread cleaned its channels
  # We just need to reclaim the memory
  wv_free(globalCtx.com.thefts)
  wv_free(globalCtx.com.tasks)

  # The root task has no parent
  ascertain: myTask().isRootTask()
  delete(myTask())

  # TODO takeover the leftover pools

  metrics:
    log("+========================================+\n")

proc exit*(_: type Weave) =
  syncRoot(_)
  signalTerminate(nil)
  localCtx.signaledTerminate = true

  # 1 matching barrier in worker_entry_fn
  discard globalCtx.barrier.wait()

  # 1 matching barrier in metrics
  workerMetrics()

  threadLocalCleanup()
  globalCleanup()
