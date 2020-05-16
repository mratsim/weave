# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import synthesis

import
  ../instrumentation/[contracts, profilers, loggers],
  ../primitives/barriers,
  ../datatypes/[sync_types, prell_deques, context_thread_local],
  ../cross_thread_com/scoped_barriers,
  ../memory/lookaside_lists,
  ../contexts, ../config,
  ../victims,
  ../thieves, ../workers,
  ./recv_task_else_steal, ./dispatch_events

# Scoped Barrier - Finite state machine
# ----------------------------------------------------------------------------------

# This file synthesizes a finite state machine
# that represent a scoped barrier.
#
# A scoped barrier prevents a thread from continuing
# until all the descendant tasks are finished.
#
# The awaiting thread continues to help the runtime
# by sharing the workload.

# Note: we can focus on the child tasks of the current task
# by calling `myWorker().deque.popFirstIfChild(myTask())`
# instead of `myWorker().deque.popFirst(myTask())`
#
# but this seems to livelock the root thread from time to time
# i.e. the task in deque could be a grandchildren task
# and so is not cleared and then the root thread is stuck trying to steal
# from idle threads.
#
# Furthermore while `sync_scope` guarantees only waiting for tasks created in the scope
# and not emptying all tasks, doing so satistfies the "greedy" scheduler requirement
# to have the asymptotically optimal speedup. (i.e. as long as there are tasks, workers are progressing on them)

type ScopedBarrierState = enum
  SB_CheckTask
  SB_OutOfTasks
  SB_Steal
  SB_SuccessfulTheft

type ScopedBarrierEvent = enum
  SBE_NoDescendants
  SBE_HasTask
  SBE_ReceivedTask

declareAutomaton(syncScopeFSA, ScopedBarrierState, ScopedBarrierEvent)
setPrologue(syncScopeFSA):
  var task: Task
  debug: log("Worker %2d: syncScope 1 - task from local deque\n", myID())


setInitialState(syncScopeFSA, SB_CheckTask)
setTerminalState(syncScopeFSA, SB_Exit)

# -------------------------------------------

implEvent(syncScopeFSA, SBE_NoDescendants):
  hasDescendantTasks(scopedBarrier)

behavior(syncScopeFSA):
  # In SB_Steal state we might recv tasks and steal requests which get stuck
  # in our queues when we exit once we have no descendant left.
  ini: [SB_CheckTask, SB_OutOfTasks, SB_Steal]
  interrupt: SBE_NoDescendants
  transition: discard
  fin: SB_Exit

implEvent(syncScopeFSA, SBE_HasTask):
  not task.isNil

onEntry(syncScopeFSA, SB_CheckTask):
  task = nextTask(childTask = false)

behavior(syncScopeFSA):
  ini: SB_CheckTask
  event: SBE_HasTask
  transition:
    profile(run_task):
      execute(task)
    profile(enq_deq_task):
      workerContext.taskCache.add(task)
  fin: SB_CheckTask

behavior(syncScopeFSA):
  ini: SB_CheckTask
  transition:
    # 2. Run out-of-task, become a thief and help other threads
    #    to reach their children faster
    debug: log("Worker %2d: syncScope 2 - becoming a thief\n", myID())
  fin: SB_OutOfTasks

# -------------------------------------------
# These states are interrupted when the scope has no more descendant

behavior(syncScopeFSA):
  ini: SB_OutOfTasks
  transition:
    # Steal and hope to advance towards the child tasks in other workers' queues.
    trySteal(isOutOfTasks = false) # Don't sleep here or we might stall the runtime
    profile_start(idle)
  fin: SB_Steal

onEntry(syncScopeFSA, SB_Steal):
  let lootedTask = recvElseSteal(task, isOutOfTasks = false) # Don't sleep here or we might stall the runtime

implEvent(syncScopeFSA, SBE_ReceivedTask):
  lootedTask

behavior(syncScopeFSA):
  ini: SB_Steal
  event: SBE_ReceivedTask
  transition: profile_stop(idle)
  fin: SB_SuccessfulTheft

behavior(syncScopeFSA):
  steady: SB_Steal
  transition:
    profile_stop(idle)
    dispatchToChildrenAndThieves()
    profile_start(idle)

# -------------------------------------------
# This is not interrupted when scoped barrier has no descendant tasks

behavior(syncScopeFSA):
  ini: SB_SuccessfulTheft
  transition:
    ascertain: not task.fn.isNil
    debug: log("Worker %2d: syncScope 3 - stoled tasks\n", myID())
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

    # Share loot with children workers
    debug: log("Worker %2d: syncScope 4 - sharing work\n", myID())
    shareWork()

    # Run the rest
    profile(run_task):
      execute(task)
    profile(enq_deq_task):
      # The memory is re-used but not zero-ed
      workerContext.taskCache.add(task)
  fin: SB_CheckTask

# -------------------------------------------

synthesize(syncScopeFSA):
  proc wait(scopedBarrier: var ScopedBarrier) {.gcsafe.}

# Public
# -------------------------------------------

template syncScope*(body: untyped): untyped =
  bind wait
  block:
    let suspendedScope = mySyncScope()
    var scopedBarrier {.noInit.}: ScopedBarrier
    initialize(scopedBarrier)
    mySyncScope() = addr(scopedBarrier)
    body
    wait(scopedBarrier)
    mySyncScope() = suspendedScope

# Dump the graph
# -------------------------------------------

when isMainModule:
  const dotRepr = toGraphviz(syncScopeFSA)
  writeFile("weave/state_machines/sync_scope.dot", dotRepr)
