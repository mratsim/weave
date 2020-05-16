# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import synthesis

import
  ../instrumentation/[contracts, loggers],
  ../datatypes/[sync_types, prell_deques, context_thread_local],
  ../contexts, ../config,
  ../victims, ../loop_splitting,
  ../thieves,
  ../cross_thread_com/channels_mpsc_unbounded_batch

# Scheduler - Finite Automaton rewrite
# ----------------------------------------------------------------------------------
# This file is temporary and is used to make
# progressive refactoring of the codebase to
# finite state machine code.

type IncomingThievesState = enum
  IT_CheckTheft
  IT_IncomingReq
  IT_ManagerCheckJob
  IT_CheckSplit
  IT_Split

type IT_Event = enum
  ITE_FoundReq
  ITE_FoundTask
  ITE_Manager
  ITE_FoundJob
  ITE_CanSplit
  ITE_ReqIsMine

declareAutomaton(handleThievesFSA, IncomingThievesState, IT_Event)
setInitialState(handleThievesFSA, IT_CheckTheft)
setTerminalState(handleThievesFSA, IT_Exit)

setPrologue(handleThievesFSA):
  ## Check if someone tries to steal from us
  ## Send them extra tasks if we have them or
  ## split our popped task if possible
  var req: StealRequest

# Theft
# ------------------------------------------------------

implEvent(handleThievesFSA, ITE_FoundReq):
  recv(req)

behavior(handleThievesFSA):
  ini: IT_CheckTheft
  event: ITE_FoundReq
  transition: discard
  fin: IT_IncomingReq

behavior(handleThievesFSA):
  ini: IT_CheckTheft
  transition: discard
  fin: IT_Exit

# Task
# ------------------------------------------------------

implEvent(handleThievesFSA, ITE_FoundTask):
  not myWorker.deque.isEmpty()

implEvent(handleThievesFSA, ITE_Manager):
  workerIsManager()

# TODO, can we optimize by checking who the thief is before this step
behavior(handleThievesFSA):
  ini: IT_IncomingReq
  event: ITE_FoundTask
  transition: dispatchElseDecline(req)
  fin: IT_CheckTheft

behavior(handleThievesFSA):
  # Fallback to check split
  ini: IT_IncomingReq
  event: ITE_Manager
  transition: discard
  fin: IT_ManagerCheckJob

behavior(handleThievesFSA):
  # Fallback to check split
  ini: IT_IncomingReq
  transition: discard
  fin: IT_CheckSplit

# Job
# ------------------------------------------------------

onEntry(handleThievesFSA, IT_ManagerCheckJob):
  var job: Job
  let foundJob = managerJobQueue.tryRecv(job)

implEvent(handleThievesFSA, ITE_FoundJob):
  foundJob

behavior(handleThievesFSA):
  ini: IT_ManagerCheckJob
  event: ITE_FoundJob
  transition:
    # TODO: not pretty to enqueue, to dequeue just after in dispatchElseDecline
    debugExecutor:
      log("Manager %d: schedule a new job for execution.\n", myID)
    myWorker().deque.addFirst cast[Task](job)
    req.dispatchElseDecline()
  fin: IT_CheckTheft

behavior(handleThievesFSA):
  # Fallback to check split
  ini: IT_ManagerCheckJob
  transition: discard
  fin: IT_CheckSplit

# Split
# ------------------------------------------------------

implEvent(handleThievesFSA, ITE_CanSplit):
  # If we just popped a loop task, we may split it here
  # It makes dispatching tasks simpler
  # Don't send our popped task otherwise
  poppedTask.isSplittable()

implEvent(handleThievesFSA, ITE_ReqIsMine):
  req.thiefID == myID()

behavior(handleThievesFSA):
  ini: IT_CheckSplit
  event: ITE_CanSplit
  transition: discard
  fin: IT_Split

behavior(handleThievesFSA):
  # Fallback
  ini: IT_CheckSplit
  transition: dispatchElseDecline(req)
  fin: IT_CheckTheft

behavior(handleThievesFSA):
  ini: IT_Split
  event: ITE_ReqIsMine
  transition: forget(req)
  fin: IT_CheckTheft

behavior(handleThievesFSA):
  ini: IT_Split
  transition: splitAndSend(poppedTask, req, workSharing = false)
  fin: IT_CheckTheft

# -------------------------------------------

synthesize(handleThievesFSA):
  proc handleThieves*(poppedTask: Task) {.gcsafe.}

# Dump the graph
# -------------------------------------------

when isMainModule:
  const dotRepr = toGraphviz(handleThievesFSA)
  writeFile("weave/state_machines/handle_thieves.dot", dotRepr)
