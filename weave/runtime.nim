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
  ./datatypes/[sync_types, prell_deques],
  ./channels/[channels_mpsc_bounded_lock, channels_spsc_single_ptr],
  ./memory/[persistacks, intrusive_stacks, allocs],
  ./scheduler, ./signals, ./workers, ./thieves, ./victims,
  # Low-level primitives
  ./primitives/[affinity, barriers]

# Runtime public routines
# ----------------------------------------------------------------------------------

type Runtime* = object

# TODO: used to debug a recurrent deadlock on trySend with 5 workers
import ./channels/channels_legacy

proc init*(_: type Runtime) =
  # TODO detect Hyper-Threading and NUMA domain

  if existsEnv"WEAVE_NUM_THREADS":
    workforce() = getEnv"WEAVE_NUM_THREADS".parseInt.int32
    if workforce() <= 0:
      raise newException(ValueError, "WEAVE_NUM_THREADS must be > 0")
    # elif workforce() > WV_MaxWorkers:
    #   echo "WEAVE_NUM_THREADS truncated to ", WV_MaxWorkers
  else:
    workforce() = int32 countProcessors()

  ## Allocation of the global context.
  globalCtx.threadpool = wv_alloc(Thread[WorkerID], workforce())
  globalCtx.com.thefts = wv_alloc(ChannelLegacy[StealRequest], workforce())
  globalCtx.com.tasks = wv_alloc(Persistack[WV_MaxConcurrentStealPerWorker, ChannelSpscSinglePtr[Task]], workforce())
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

  myWorker().currentTask = newTaskFromCache() # Root task
  init(localCtx)
  # Wait for the child threads
  discard pthread_barrier_wait(globalCtx.barrier)

proc globalCleanup() =
  for i in 1 ..< workforce():
    joinThread(globalCtx.threadpool[i])

  discard pthread_barrier_destroy(globalCtx.barrier)
  deallocShared(globalCtx.threadpool)

  # The root task has no parent
  ascertain: myTask().isRootTask()
  delete(myTask())
  metrics:
    log("+========================================+\n")

proc exit*(_: type Runtime) =
  signalTerminate(nil)
  localCtx.signaledTerminate = true

  # 1 matching barrier in worker_entry_fn
  discard pthread_barrier_wait(globalCtx.barrier)

  # 1 matching barrier in metrics
  workerMetrics()

  threadLocalCleanup()
  globalCleanup()

proc sync*(_: type Runtime) =
  ## Global barrier for the Picasso runtime
  ## This is only valid in the root task
  Worker: return

  debugTermination:
    log(">>> Worker %d enters barrier <<<\n", myID())

  preCondition: myTask().isRootTask()

  block EmptyLocalQueue:
    ## Empty all the tasks and before leaving the barrier
    while true:
      debug: log("Worker %d: globalsync 1 - task from local deque\n", myID())
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
      debug: log("Worker %d: globalsync 2 - becoming a thief\n", myID())
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
      debug: log("Worker %d: globalsync 3 - stoled tasks\n", myID())
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
      debug: log("Worker %d: globalsync 4 - sharing work\n", myID())
      shareWork()

      # 5. Work on what is left
      debug: log("Worker %d: globalsync 5 - working on leftover\n", myID())
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
    log(">>> Worker %d leaves barrier <<<\n", myID())
