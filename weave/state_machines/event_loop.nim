# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import synthesis

import
  # Internal
  ../instrumentation/[contracts, profilers, loggers],
  ../contexts, ../config,
  ../datatypes/[sync_types, prell_deques],
  ../memory/lookaside_lists,
  ../workers, ../thieves, ../victims,
  ./handle_thieves, ./recv_task_else_steal,
  ./dispatch_events

# Worker Event Loop
# ----------------------------------------------------------------------------------

type
  WorkerState = enum
    WEL_CheckTermination
    WEL_CheckTask
    WEL_OutOfTasks
    WEL_SuccessfulTheft

  WorkerEvent = enum
    EV_SignaledTerminate
    EV_FoundTask # Found task in our task deque
    EV_StoleTask # Stole at least a task

declareAutomaton(workerEventLoop, WorkerState, WorkerEvent)

setPrologue(workerEventLoop):
  ## Event loop
  ## Each worker besides the root thread execute this loop
  ## over and over until they are signaled to terminate
  ##
  ## Termination is sent as an asynchronous task that updates the
  ## worker local context.
  var task: Task

setInitialState(workerEventLoop, WEL_CheckTermination)
setTerminalState(workerEventLoop, WEL_Exit)

# -------------------------------------------

implEvent(workerEventLoop, EV_SignaledTerminate):
  workerContext.signaledTerminate

behavior(workerEventLoop):
  ini: WEL_CheckTermination
  event: EV_SignaledTerminate
  transition: discard
  fin: WEL_Exit

behavior(workerEventLoop):
  ini: WEL_CheckTermination
  fin: WEL_CheckTask
  transition:
    # debug: log("Worker %2d: schedloop 1 - task from local deque\n", myID())
    discard

# -------------------------------------------
# 1. Private task deque

onEntry(workerEventLoop, WEL_CheckTask):
  # If we have extra tasks, prio is: children, then thieves then us
  # This is done in `nextTask`
  let task = nextTask(childTask = false)

implEvent(workerEventLoop, EV_FoundTask):
  not task.isNil

behavior(workerEventLoop):
  ini: WEL_CheckTask
  event: EV_FoundTask
  transition:
    ascertain: not task.fn.isNil
    profile(run_task):
      execute(task)
    profile(enq_deq_task):
      # The task memory is reused but not zero-ed
      workerContext.taskCache.add(task)
  fin: WEL_CheckTask

behavior(workerEventLoop):
  ini: WEL_CheckTask
  fin: WEL_OutOfTasks
  transition:
    # debug: log("Worker %2d: schedloop 2 - becoming a thief\n", myID())
    trySteal(isOutOfTasks = true)
    ascertain: myThefts().outstanding > 0
    profile_start(idle)

# -------------------------------------------
# 2. Run out-of-task, become a thief

onEntry(workerEventLoop, WEL_OutOfTasks):
  # task = nil
  let stoleTask = task.recvElseSteal(isOutOfTasks = true)

implEvent(workerEventLoop, EV_StoleTask):
  stoleTask

behavior(workerEventLoop):
  steady: WEL_OutOfTasks
  transition:
    ascertain: myWorker().deque.isEmpty()
    ascertain: myThefts().outstanding > 0
    declineAll()

behavior(workerEventLoop):
  ini: WEL_OutOfTasks
  event: EV_StoleTask
  transition: profile_stop(idle)
  fin: WEL_SuccessfulTheft

# -------------------------------------------

behavior(workerEventLoop):
  ini: WEL_SuccessfulTheft
  transition:
    # 3. We stole some task(s)
    ascertain: not task.fn.isNil
    # debug: log("Worker %2d: schedloop 3 - stoled tasks\n", myID())
    TargetLastVictim:
      if task.victim != Not_a_worker:
        myThefts().lastVictim = task.victim
        ascertain: myThefts().lastVictim != myID()

    if not task.next.isNil:
      # Add everything
      myWorker().deque.addListFirst(task)
      # And then only use the last
      task = myWorker().deque.popFirst()

    StealAdaptative:
      myThefts().recentThefts += 1

    # 4. Share loot with children
    # debug: log("Worker %2d: schedloop 4 - sharing work\n", myID())
    shareWork()

    # 5. Work on what is left
    # debug: log("Worker %2d: schedloop 5 - working on leftover\n", myID())
    profile(run_task):
      execute(task)
    profile(enq_deq_task):
      # The memory is reused but not zero-ed
      workerContext.taskCache.add(task)
  fin: WEL_CheckTermination

# -------------------------------------------

synthesize(workerEventLoop):
  proc eventLoop*() {.gcsafe.}

# Dump the graph
# -------------------------------------------

when isMainModule:
  const dotRepr = toGraphviz(workerEventLoop)
  writeFile("weave/state_machines/event_loop.dot", dotRepr)
