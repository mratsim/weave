# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import synthesis

import
  # Standard library
  os, cpuinfo, strutils,
  # Internal
  ./instrumentation/[contracts, profilers, loggers],
  ./contexts, ./config,
  ./datatypes/[sync_types, prell_deques, binary_worker_trees],
  ./channels/[channels_spsc_single_ptr, channels_mpsc_unbounded_batch],
  ./memory/[persistacks, lookaside_lists, allocs, memory_pools],
  ./scheduler, ./signals, ./workers, ./thieves, ./victims, ./work_fsm,
  ./runtime, scheduler_fsm,
  # Low-level primitives
  ./primitives/barriers

# Runtime - Finite Automaton rewrite
# ----------------------------------------------------------------------------------
# This file is temporary and is used to make
# progressive refactoring of the codebase to
# finite state machine code.

type
  SyncState = enum
    SY_CheckTask
    SY_OutOfTasks
    SY_Steal
    SY_SuccessfulTheft

  SyncEvent = enum
    SYE_HasTask
    SYE_SoleWorker
    SYE_Quiescent
    SYE_ReceivedTask

declareAutomaton(syncFSA, SyncState, SyncEvent)

setPrologue(syncFSA):
  ## Global barrier for the Weave runtime
  ## This is only valid in the root task
  Worker: return
  debugTermination:
    log(">>> Worker %2d enters barrier <<<\n", myID())
  preCondition: myTask().isRootTask()

  debug: log("Worker %2d: globalsync 1 - task from local deque\n", myID())
  var task: Task

setEpilogue(syncFSA):
  # Execution continues but the runtime is quiescent until new tasks
  # are created
  postCondition: localCtx.runtimeIsQuiescent
  debugTermination:
    log(">>> Worker %2d leaves barrier <<<\n", myID())

setInitialState(syncFSA, SY_CheckTask)
setTerminalState(syncFSA, SY_Exit)

# -------------------------------------------

implEvent(syncFSA, SYE_HasTask):
  not task.isNil

implEvent(syncFSA, SYE_Quiescent):
  localCtx.runtimeIsQuiescent

implEvent(syncFSA, SYE_SoleWorker):
  workforce() == 1

# -------------------------------------------

onEntry(syncFSA, SY_CheckTask):
  task = myWorker().deque.popFirst()
  # TODO steal early
  shareWork()
  # Check if someone requested to steal from us
  # Send them extra tasks if we have them
  # or split our popped task if possible
  handleThieves(task)

behavior(syncFSA):
  ini: SY_CheckTask
  event: SYE_HasTask
  transition:
    profile(run_task):
      runTask(task)
    profile(enq_deq_task):
      localCtx.taskCache.add(task)
  fin: SY_CheckTask

behavior(syncFSA):
  ini: SY_CheckTask
  transition: discard
  fin: SY_OutOfTasks

# -------------------------------------------

behavior(syncFSA):
  ini: SY_OutOfTasks
  event: SYE_SoleWorker
  transition: localCtx.runtimeIsQuiescent = true
  fin: SY_Exit

behavior(syncFSA):
  ini: SY_OutOfTasks
  event: SYE_Quiescent
  transition: discard
  fin: SY_Exit

behavior(syncFSA):
  ini: SY_OutOfTasks
  transition:
    # 2. Run out-of-task, become a thief and help other threads
    #    to reach the barrier faster
    debug: log("Worker %2d: globalsync 2 - becoming a thief\n", myID())
    trySteal(isOutOfTasks = true)
    ascertain: myThefts().outstanding > 0
    profile_start(idle)
  fin: SY_Steal

# -------------------------------------------

onEntry(syncFSA, SY_Steal):
  let hasTask = recvElseSteal(task, isOutOfTasks = true)

implEvent(syncFSA, SYE_ReceivedTask):
  hasTask

behavior(syncFSA):
  ini: SY_Steal
  interrupt: SYE_Quiescent
  transition: profile_stop(idle)
  fin: SY_Exit

behavior(syncFSA):
  ini: SY_Steal
  event: SYE_ReceivedTask
  transition: profile_stop(idle)
  fin: SY_SuccessfulTheft

behavior(syncFSA):
  steady: SY_Steal
  transition:
    ascertain: myWorker().deque.isEmpty()
    ascertain: myThefts().outstanding > 0
    declineAll()

# -------------------------------------------

behavior(syncFSA):
  ini: SY_SuccessfulTheft
  transition:
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
      runTask(task)
    profile(enq_deq_task):
      # The memory is reused but not zero-ed
      localCtx.taskCache.add(task)
  fin: SY_CheckTask

# -------------------------------------------

synthesize(syncFSA):
  proc sync*(_: type Weave) {.gcsafe.}

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
  sync(_)
  signalTerminate(nil)
  localCtx.signaledTerminate = true

  # 1 matching barrier in worker_entry_fn
  discard globalCtx.barrier.wait()

  # 1 matching barrier in metrics
  workerMetrics()

  threadLocalCleanup()
  globalCleanup()
