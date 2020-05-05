# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import synthesis

import
  ../instrumentation/[contracts, profilers, loggers],
  ../datatypes/[sync_types, prell_deques, flowvars],
  ../memory/lookaside_lists,
  ../contexts, ../config,
  ../victims,
  ../thieves, ../workers,
  ./recv_task_else_steal, ./dispatch_events

# Await/sync future - Finite Automaton rewrite
# ----------------------------------------------------------------------------------

type AwaitState = enum
  AW_CheckTask
  AW_OutOfDirectChildTasks
  AW_Steal
  AW_SuccessfulTheft

type AwaitEvent = enum
  AWE_FutureReady
  AWE_HasChildTask
  AWE_ReceivedTask

declareAutomaton(awaitFSA, AwaitState, AwaitEvent)
setPrologue(awaitFSA):
  ## Eagerly complete an awaited FlowVar

  # TODO: tasks cannot be printed by "ascertain"
  # when compileOption("assertions"):
  #   # Ensure that we keep hold on the task we are awaiting
  #   let thisTask = myTask()

  var task: Task
  debug: log("Worker %2d: forcefut 1 - task from local deque\n", myID())

setInitialState(awaitFSA, AW_CheckTask)
setTerminalState(awaitFSA, AW_Exit)

# -------------------------------------------

implEvent(awaitFSA, AWE_FutureReady):
  tryComplete(fv, parentResult)

behavior(awaitFSA):
  # In AW_Steal we might recv tasks and steal requests which get stuck in our queues
  # when we exit once the future is ready.
  ini: [AW_CheckTask, AW_OutOfDirectChildTasks, AW_Steal]
  interrupt: AWE_FutureReady
  transition: discard
  fin: AW_Exit

implEvent(awaitFSA, AWE_HasChildTask):
  not task.isNil

onEntry(awaitFSA, AW_CheckTask):
  task = nextTask(childTask = true)

behavior(awaitFSA):
  ini: AW_CheckTask
  event: AWE_HasChildTask
  transition:
    profile(run_task):
      execute(task)
    profile(enq_deq_task):
      localCtx.taskCache.add(task)
  fin: AW_CheckTask

behavior(awaitFSA):
  ini: AW_CheckTask
  transition:
    # TODO: cannot be printed
    # ascertain: myTask() == thisTask

    # 2. Run out-of-task, become a thief and help other threads
    #    to reach children faster
    debug: log("Worker %2d: forcefut 2 - becoming a thief\n", myID())
  fin: AW_OutOfDirectChildTasks

# -------------------------------------------
# These states are interrupted when future is ready

behavior(awaitFSA):
  ini: AW_OutOfDirectChildTasks
  transition:
    # Steal and hope to advance towards the child tasks in other workers' queues.
    trySteal(isOutOfTasks = false)
    # If someone wants our non-direct child tasks, let's oblige
    # Note that we might have grandchildren tasks stuck in our own queue.
    dispatchToChildrenAndThieves()
    profile_start(idle)
  fin: AW_Steal

onEntry(awaitFSA, AW_Steal):
  let lootedTask = recvElseSteal(task, isOutOfTasks = false)

implEvent(awaitFSA, AWE_ReceivedTask):
  lootedTask

behavior(awaitFSA):
  ini: AW_Steal
  event: AWE_ReceivedTask
  transition: profile_stop(idle)
  fin: AW_SuccessfulTheft

behavior(awaitFSA):
  steady: AW_Steal
  transition:
    # We might inadvertently remove our own steal request in
    # dispatchElseDecline so resteal
    profile_stop(idle)
    trySteal(isOutOfTasks = false)
    # If someone wants our non-direct child tasks, let's oblige
    # Note that we might have grandchildren tasks stuck in our own queue.
    dispatchToChildrenAndThieves()
    profile_start(idle)

# -------------------------------------------
# This is not interrupted when future is ready

behavior(awaitFSA):
  ini: AW_SuccessfulTheft
  transition:
    ascertain: not task.fn.isNil
    debug: log("Worker %2d: forcefut 3 - stoled tasks\n", myID())
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
    debug: log("Worker %2d: forcefut 4 - sharing work\n", myID())
    shareWork()

    # Run the rest
    profile(run_task):
      execute(task)
    profile(enq_deq_task):
      # The memory is reused but not zero-ed
      localCtx.taskCache.add(task)
  fin: AW_OutOfDirectChildTasks

# -------------------------------------------

synthesize(awaitFSA):
  proc forceFuture[T](fv: Flowvar[T], parentResult: var T)

# -------------------------------------------

EagerFV:
  proc forceComplete[T](fv: Flowvar[T], parentResult: var T) {.inline.} =
    ## From the parent thread awaiting on the result, force its computation
    ## by eagerly processing only the child tasks spawned by the awaited task
    fv.forceFuture(parentResult)
    recycleChannel(fv)

LazyFV:
  template forceComplete[T](fv: Flowvar[T], parentResult: var T) =
    forceFuture(fv, parentResult)
    # Reclaim memory
    if not fv.lfv.hasChannel:
      ascertain: fv.lfv.isReady
      parentResult = cast[ptr T](fv.lfv.lazy.buf.addr)[]
    else:
      ascertain: not fv.lfv.lazy.chan.isNil
      recycleChannel(fv)

# Public
# -------------------------------------------

proc sync*[T](fv: FlowVar[T]): T {.inline.} =
  ## Blocks the current thread until the flowvar is available
  ## and returned.
  ## The thread is not idle and will complete pending tasks.
  fv.forceComplete(result)


# Dump the graph
# -------------------------------------------

when isMainModule:
  const dotRepr = toGraphviz(awaitFSA)
  writeFile("weave/state_machines/sync.dot", dotRepr)
