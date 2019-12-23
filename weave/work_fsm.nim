# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import synthesis

import
  ./datatypes/[sync_types, context_thread_local],
  ./contexts,
  ./instrumentation/[contracts, profilers, loggers],
  ./channels/channels_spsc_single_ptr,
  ./memory/persistacks,
  ./config,
  ./thieves, ./workers

# Workers - Finite Automaton rewrite
# ----------------------------------------------------------------------------------
# This file is temporary and is used to make
# progressive refactoring of the codebase to
# finite state machine code.

type
  RecvTaskState = enum
    RT_CheckChannel
    RT_FoundTask

  RT_Event = enum
    RTE_CheckedAllChannels
    RTE_FoundTask
    RTE_isWaiting

declareAutomaton(recvTaskFSA, RecvTaskState, RT_Event)

setPrologue(recvTaskFSA):
  ## Check the worker task channel for a task successfully stolen
  ##
  ## Updates task and returns true if a task was found
  var curChanIdx = 0
  profile_init(send_recv_task)

setInitialState(recvTaskFSA, RT_CheckChannel)
setTerminalState(recvTaskFSA, RT_Exit)

# Steal and exit if we get no tasks
# -------------------------------------------

implEvent(recvTaskFSA, RTE_CheckedAllChannels):
  curChanIdx == WV_MaxConcurrentStealPerWorker

behavior(recvTaskFSA):
  ini: RT_CheckChannel
  interrupt: RTE_CheckedAllChannels
  transition:
    profile_stop(send_recv_task)
    trySteal(isOutofTasks)
  fin: RT_Exit

# -------------------------------------------

implEvent(recvTaskFSA, RTE_FoundTask):
  result

onEntry(recvTaskFSA, RT_CheckChannel):
  result = myTodoBoxes().access(curChanIdx).tryRecv(task)

behavior(recvTaskFSA):
  steady: RT_CheckChannel
  transition:
    curChanIdx += 1

behavior(recvTaskFSA):
  ini: RT_CheckChannel
  event: RTE_FoundTask
  transition:
    myTodoBoxes().nowAvailable(curChanIdx)
    localCtx.stealCache.nowAvailable(curChanIdx)
    debug: log("Worker %2d: received a task with function address 0x%.08x (Channel 0x%.08x)\n",
      myID(), task.fn, myTodoBoxes().access(curChanIdx).addr)
    profile_stop(send_recv_task)
  fin: RT_FoundTask

# -------------------------------------------

onExit(recvTaskFSA, RT_FoundTask):
  # Steal request fulfilled
  myThefts().outstanding -= 1

  debug: log("Worker %2d: %d theft(s) outstanding after receiving a task\n", myID(), myThefts().outstanding)
  postCondition: myThefts().outstanding in 0 ..< WV_MaxConcurrentStealPerWorker
  postCondition: myThefts().dropped == 0

implEvent(recvTaskFSA, RTE_isWaiting):
  myWorker().isWaiting

behavior(recvTaskFSA):
  ini: RT_FoundTask
  event: RTE_isWaiting
  transition: restartWork()
  fin: RT_Exit

behavior(recvTaskFSA):
  ini: RT_FoundTask
  transition:
    when WV_MaxConcurrentStealPerWorker == 1:
      # If we have dropped one or more steal requests before receiving
      # tasks, adjust outstanding to make sure that we can send MaxSteal
      # steal requests again
      ascertain: myThefts().outstanding > myThefts().dropped
      myThefts().outstanding -= myThefts().dropped
      myThefts().dropped = 0
  fin: RT_Exit

# -------------------------------------------

synthesize(recvTaskFSA):
  proc recv*(task: var Task, isOutOfTasks: bool): bool
