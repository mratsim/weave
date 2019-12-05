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
  ./channels/[channels_spsc_single_ptr, channels_mpsc_unbounded_batch, event_notifiers],
  ./memory/[persistacks, lookaside_lists, allocs, memory_pools],
  ./scheduler, ./signals, ./workers, ./thieves, ./victims,
  # Low-level primitives
  ./primitives/[affinity, barriers]

# Runtime public routines
# ----------------------------------------------------------------------------------

type Weave* = object

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
  # globalCtx.com.parking = wv_alloc(EventNotifier, workforce())
  discard pthread_barrier_init(globalCtx.barrier, nil, workforce())

  # Lead thread - pinned to CPU 0
  myID() = 0
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
    pinToCpu(globalCtx.threadpool[i], i)

  myMemPool().initialize(myID())
  myWorker().currentTask = newTaskFromCache() # Root task
  init(localCtx)
  # Wait for the child threads
  discard pthread_barrier_wait(globalCtx.barrier)

proc globalCleanup() =
  for i in 1 ..< workforce():
    joinThread(globalCtx.threadpool[i])

  discard pthread_barrier_destroy(globalCtx.barrier)
  deallocShared(globalCtx.threadpool)

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

proc sync*(_: type Weave) =
  ## Global barrier for the Picasso runtime
  ## This is only valid in the root task
  Worker: return

  debugTermination:
    log(">>> Worker %2d enters barrier <<<\n", myID())

  preCondition: myTask().isRootTask()

  block EmptyLocalQueue:
    ## Empty all the tasks and before leaving the barrier
    while true:
      debug: log("Worker %2d: globalsync 1 - task from local deque\n", myID())
      while (let task = nextTask(childTask = false); not task.isNil):
        # TODO: duplicate schedulingLoop
        profile(run_task):
          run(task)
        profile(enq_deq_task):
          # The memory is reused but not zero-ed
          localCtx.taskCache.add(task)

      if workforce() == 1:
        localCtx.runtimeIsQuiescent = true
        break EmptyLocalQueue

      if localCtx.runtimeIsQuiescent:
        break EmptyLocalQueue

      # 2. Run out-of-task, become a thief and help other threads
      #    to reach the barrier faster
      debug: log("Worker %2d: globalsync 2 - becoming a thief\n", myID())
      trySteal(isOutOfTasks = true)
      ascertain: myThefts().outstanding > 0

      var task: Task
      profile(idle):
        while not recv(task, isOutOfTasks = true):
          ascertain: myWorker().deque.isEmpty()
          ascertain: myThefts().outstanding > 0
          declineAll()
          if localCtx.runtimeIsQuiescent:
            # Goto breaks profiling, but the runtime is still idle
            break EmptyLocalQueue


      # 3. We stole some task(s)
      debug: log("Worker %2d: globalsync 3 - stoled tasks\n", myID())
      ascertain: not task.fn.isNil

      let loot = task.batch
      if loot > 1:
        profile(enq_deq_task):
          # Add everything
          myWorker().deque.addListFirst(task, loot)
          # And then only use the last
          task = myWorker().deque.popFirst()

      StealAdaptative:
        myThefts().recentThefts += 1

      # 4. Share loot with children
      debug: log("Worker %2d: globalsync 4 - sharing work\n", myID())
      shareWork()

      # 5. Work on what is left
      debug: log("Worker %2d: globalsync 5 - working on leftover\n", myID())
      profile(run_task):
        run(task)
      profile(enq_deq_task):
        # The memory is reused but not zero-ed
        localCtx.taskCache.add(task)

    # Restart the loop

  # Execution continues but the runtime is quiescent until new tasks
  # are created
  postCondition: localCtx.runtimeIsQuiescent

  debugTermination:
    log(">>> Worker %2d leaves barrier <<<\n", myID())

proc exit*(_: type Weave) =
  sync(_)
  signalTerminate(nil)
  localCtx.signaledTerminate = true

  # 1 matching barrier in worker_entry_fn
  discard pthread_barrier_wait(globalCtx.barrier)

  # 1 matching barrier in metrics
  workerMetrics()

  threadLocalCleanup()
  globalCleanup()

proc loadBalance*(_: type Weave) =
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
  if myThieves().peek() != 0:
    #  myWorker().leftIsWaiting and hasThievesProxy(myWorker().left) or
    #  myWorker().rightIsWaiting and hasThievesProxy(myWorker().right):
    var req: StealRequest
    while recv(req):
      dispatchTasks(req)
