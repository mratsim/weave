# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import synthesis

import
  # Standard library
  os,
  # Internal
  ../instrumentation/[contracts, profilers, loggers],
  ../contexts, ../config,
  ../datatypes/[sync_types, prell_deques],
  ../cross_thread_com/channels_spsc_single_ptr,
  ../memory/lookaside_lists,
  ../workers, ../thieves, ../victims,
  ./recv_task_else_steal,
  ./dispatch_events

# Sync Root - Global runtime barrier
# ----------------------------------------------------------------------------------

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

declareAutomaton(syncRootFSA, SyncState, SyncEvent)

setPrologue(syncRootFSA):
  ## Root task barrier for the Weave runtime
  ##
  ## The main thread stops until all worker threads run out of tasks.
  ##
  ## This is only valid in the root task and main thread
  ## Usage in a region that can be called from multiple threads
  ## will result in undefined behavior.
  Worker: return
  debugTermination:
    log(">>> Worker %2d enters barrier <<<\n", myID())
  preCondition: myTask().isRootTask()

  debug: log("Worker %2d: syncRoot 1 - task from local deque\n", myID())
  var task: Task

setEpilogue(syncRootFSA):
  # Execution continues but the runtime is quiescent until new tasks
  # are created
  postCondition: localCtx.runtimeIsQuiescent
  debugTermination:
    log(">>> Worker %2d leaves barrier <<<\n", myID())

setInitialState(syncRootFSA, SY_CheckTask)
setTerminalState(syncRootFSA, SY_Exit)

# -------------------------------------------

implEvent(syncRootFSA, SYE_HasTask):
  not task.isNil

implEvent(syncRootFSA, SYE_Quiescent):
  localCtx.runtimeIsQuiescent

implEvent(syncRootFSA, SYE_SoleWorker):
  workforce() == 1

# -------------------------------------------

onEntry(syncRootFSA, SY_CheckTask):
  task = nextTask(childTask = false)

behavior(syncRootFSA):
  ini: SY_CheckTask
  event: SYE_HasTask
  transition:
    profile(run_task):
      execute(task)
    profile(enq_deq_task):
      localCtx.taskCache.add(task)
  fin: SY_CheckTask

behavior(syncRootFSA):
  ini: SY_CheckTask
  transition: discard
  fin: SY_OutOfTasks

# -------------------------------------------

behavior(syncRootFSA):
  ini: SY_OutOfTasks
  event: SYE_SoleWorker
  transition: localCtx.runtimeIsQuiescent = true
  fin: SY_Exit

behavior(syncRootFSA):
  ini: SY_OutOfTasks
  event: SYE_Quiescent
  transition: discard
  fin: SY_Exit

behavior(syncRootFSA):
  ini: SY_OutOfTasks
  transition:
    # 2. Run out-of-task, become a thief and help other threads
    #    to reach the barrier faster
    debug: log("Worker %2d: syncRoot 2 - becoming a thief\n", myID())
    trySteal(isOutOfTasks = true)
    ascertain: myThefts().outstanding > 0
    profile_start(idle)
  fin: SY_Steal

# -------------------------------------------

onEntry(syncRootFSA, SY_Steal):
  let lootedTask = recvElseSteal(task, isOutOfTasks = true)

implEvent(syncRootFSA, SYE_ReceivedTask):
  lootedTask

behavior(syncRootFSA):
  ini: SY_Steal
  interrupt: SYE_Quiescent
  transition: profile_stop(idle)
  fin: SY_Exit

behavior(syncRootFSA):
  ini: SY_Steal
  event: SYE_ReceivedTask
  transition: profile_stop(idle)
  fin: SY_SuccessfulTheft

behavior(syncRootFSA):
  steady: SY_Steal
  transition:
    ascertain: myWorker().deque.isEmpty()
    ascertain: myThefts().outstanding > 0
    declineAll()

# -------------------------------------------

behavior(syncRootFSA):
  ini: SY_SuccessfulTheft
  transition:
    # 3. We stole some task(s)
    debug: log("Worker %2d: syncRoot 3 - stoled tasks\n", myID())
    ascertain: not task.fn.isNil
    TargetLastVictim:
      if task.victim != Not_a_worker:
        myThefts().lastVictim = task.victim
        ascertain: myThefts().lastVictim != myID()

    if not task.next.isNil:
      profile(enq_deq_task):
        # Add everything
        myWorker().deque.addListFirst(task)
        # And then only use the last
        task = myWorker().deque.popFirst()

    StealAdaptative:
      myThefts().recentThefts += 1

    # 4. Share loot with children
    debug: log("Worker %2d: syncRoot 4 - sharing work\n", myID())
    shareWork()

    # 5. Work on what is left
    debug: log("Worker %2d: syncRoot 5 - working on leftover\n", myID())
    profile(run_task):
      execute(task)
    profile(enq_deq_task):
      # The memory is reused but not zero-ed
      localCtx.taskCache.add(task)
  fin: SY_CheckTask

# -------------------------------------------

synthesize(syncRootFSA):
  proc syncRoot*(_: type Weave) {.gcsafe.}

# Dump the graph
# -------------------------------------------

when isMainModule:
  const dotRepr = toGraphviz(syncRootFSA)
  writeFile("weave/state_machines/sync_root.dot", dotRepr)
