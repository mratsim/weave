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
  ../contexts,
  ../victims, ../loop_splitting,
  ../thieves

# Scheduler - Finite Automaton rewrite
# ----------------------------------------------------------------------------------
# This file is temporary and is used to make
# progressive refactoring of the codebase to
# finite state machine code.

type IncomingThievesState = enum
  IT_CheckTheft
  IT_IncomingReq
  IT_CanSplit

type IT_Event = enum
  ITE_FoundReq
  ITE_NoTaskAndCanSplitCurrent
  ITE_ReqIsMine

declareAutomaton(handleThievesFSA, IncomingThievesState, IT_Event)
setInitialState(handleThievesFSA, IT_CheckTheft)
setTerminalState(handleThievesFSA, IT_Exit)

setPrologue(handleThievesFSA):
  ## Check if someone tries to steal from us
  ## Send them extra tasks if we have them or
  ## split our popped task if possible
  var req: StealRequest

implEvent(handleThievesFSA, ITE_FoundReq):
  recv(req)

implEvent(handleThievesFSA, ITE_NoTaskAndCanSplitCurrent):
  # If we just popped a loop task, we may split it here
  # It makes dispatching tasks simpler
  # Don't send our popped task otherwise
  myWorker().deque.isEmpty() and poppedTask.isSplittable()

implEvent(handleThievesFSA, ITE_ReqIsMine):
  req.thiefID == myID()

behavior(handleThievesFSA):
  ini: IT_CheckTheft
  event: ITE_FoundReq
  transition: discard
  fin: IT_IncomingReq

behavior(handleThievesFSA):
  ini: IT_CheckTheft
  transition: discard
  fin: IT_Exit

# TODO, can we optimize by checking who the thief is before this step
behavior(handleThievesFSA):
  ini: IT_IncomingReq
  event: ITE_NoTaskAndCanSplitCurrent
  transition: discard
  fin: IT_CanSplit

behavior(handleThievesFSA):
  ini: IT_IncomingReq
  transition: dispatchElseDecline(req)
  fin: IT_CheckTheft

behavior(handleThievesFSA):
  ini: IT_CanSplit
  event: ITE_ReqIsMine
  transition: forget(req)
  fin: IT_CheckTheft

behavior(handleThievesFSA):
  ini: IT_CanSplit
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
