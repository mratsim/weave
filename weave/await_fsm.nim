# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import synthesis

import
  ./instrumentation/[contracts, profilers, loggers],
  ./primitives/barriers,
  ./datatypes/[sync_types, prell_deques, context_thread_local, flowvars, sparsesets, binary_worker_trees, bounded_queues],
  ./channels/[channels_spsc_single_ptr, channels_mpsc_unbounded_batch, channels_spsc_single],
  ./memory/[persistacks, lookaside_lists, allocs, memory_pools],
  ./contexts, ./config,
  ./victims, ./loop_splitting,
  ./thieves, ./workers,
  ./random/rng, ./stealing_fsm, ./work_fsm, ./scheduler_fsm

# Await/sync future - Finite Automaton rewrite
# ----------------------------------------------------------------------------------
# This file is temporary and is used to make
# progressive refactoring of the codebase to
# finite state machine code.

type AwaitState = enum
  AW_CheckTask
  AW_OutOfChildTasks
  AW_Steal
  AW_SuccessfulTheft

type AwaitEvent = enum
  AWE_FutureReady
  AWE_HasChildTask
  AWE_ReceivedTask

declareAutomaton(awaitFSA, AwaitState, AwaitEvent)
setPrologue(awaitFSA):
  ## Eagerly complete an awaited FlowVar
  when compileOption("assertions"):
    # Ensure that we keep hold on the task we are awaiting
    let thisTask = myTask()

  var task: Task
  debug: log("Worker %2d: forcefut 1 - task from local deque\n", myID())

setInitialState(awaitFSA, AW_CheckTask)
setTerminalState(awaitFSA, AW_Exit)

# -------------------------------------------

EagerFV:
  template isFutReady(): untyped =
    fv.chan[].tryRecv(parentResult)
LazyFV:
  template isFutReady(): untyped =
    if fv.lfv.hasChannel:
      ascertain: not fv.lfv.lazy.chan.isNil
      fv.lfv.lazy.chan[].tryRecv(parentResult)
    else:
      fv.lfv.isReady

implEvent(awaitFSA, AWE_FutureReady):
  isFutReady()

behavior(awaitFSA):
  # In AW_Steal we might recv tasks and steal requests which get stuck in our queues
  # when we exit once the future is ready.
  ini: [AW_CheckTask, AW_OutOfChildTasks, AW_Steal]
  interrupt: AWE_FutureReady
  transition: discard
  fin: AW_Exit

implEvent(awaitFSA, AWE_HasChildTask):
  not task.isNil

onEntry(awaitFSA, AW_CheckTask):
  task = myWorker().deque.popFirstIfChild(myTask())

  when WV_StealEarly > 0:
    if not task.isNil:
      # If we have a big loop should we allow early thefts?
      stealEarly()

  shareWork()
  # Check if someone requested to steal from us
  # Send them extra tasks if we have them
  # or split our popped task if possible
  handleThieves(task)

behavior(awaitFSA):
  ini: AW_CheckTask
  event: AWE_HasChildTask
  transition:
    profile(run_task):
      runTask(task)
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
  fin: AW_OutOfChildTasks

# -------------------------------------------
# These states are interrupted when future is ready

behavior(awaitFSA):
  ini: AW_OutOfChildTasks
  transition:
    trySteal(isOutOfTasks = false)
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
    # If someone wants our non-child tasks, let's oblige
    var req: StealRequest
    while recv(req):
      dispatchElseDecline(req)
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
      runTask(task)
    profile(enq_deq_task):
      # The memory is reused but not zero-ed
      localCtx.taskCache.add(task)
  fin: AW_OutOfChildTasks

# -------------------------------------------

synthesize(awaitFSA):
  proc forceFuture*[T](fv: Flowvar[T], parentResult: var T)
