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
  ./work_fsm, ./scheduler_fsm

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

type ScopedBarrierState = enum
  SB_CheckTask
  SB_OutOfChildTasks
  SB_Steal
  SB_SuccessfulTheft

type ScopedBarrierEvent = enum
  SBE_NoDescendants
  SBE_HasChildTask
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
  ini: [SB_CheckTask, SB_OutOfChildTasks, SB_Steal]
  interrupt: SBE_NoDescendants
  transition: discard
  fin: SB_Exit

implEvent(syncScopeFSA, SBE_HasChildTask):
  not task.isNil

onEntry(syncScopeFSA, SB_CheckTask):
  task = myWorker().deque.popFirstIfChild(myTask())

  when WV_StealEarly > 0:
    if not task.isNil:
      # If we have a big loop should we allow early theft?
      stealEarly()

  shareWork()
  # Check if someone requested to steal from us
  # send them extra tasks if we have them
  # or split our popped task if possible
  handleThieves(task)

behavior(syncScopeFSA):
  ini: SB_CheckTask
  event: SBE_HasChildTask
  transition:
    profile(run_task):
      runTask(task)
    profile(enq_deq_task):
      localCtx.taskCache.add(task)
  fin: SB_CheckTask

behavior(syncScopeFSA):
  ini: SB_CheckTask
  transition:
    # 2. Run out-of-task, become a thief and help other threads
    #    to reach their children faster
    debug: log("Worker %2d: syncScope 2 - becoming a thief\n", myID())
  fin: SB_OutOfChildTasks

# -------------------------------------------
# These states are interrupted when the scope has no more descendant

behavior(syncScopeFSA):
  ini: SB_OutOfChildTasks
  transition:
    trySteal(isOutOfTasks = false)
    profile_start(idle)
  fin: SB_Steal

onEntry(syncScopeFSA, SB_Steal):
  let lootedTask = recvElseSteal(task, isOutOfTasks = false)

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
    # We might inadvertently remove our own steal request in
    # dispatchElseDecline so resteal
    profile_stop(idle)
    trySteal(isOutOfTasks = false)
    # If someone wants our non-child tasks, let's oblige
    var req: StealRequest
    while recv(req):
      dispatchElseDecline(req)
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
      runTask(task)
    profile(enq_deq_task):
      # The memory is re-used but not zero-ed
      localCtx.taskCache.add(task)
  fin: SB_OutOfChildTasks

# -------------------------------------------

synthesize(syncScopeFSA):
  proc wait(scopedBarrier: var ScopedBarrier)

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
  writeFile("weave/sync_scope_fsm.dot", dotRepr)
