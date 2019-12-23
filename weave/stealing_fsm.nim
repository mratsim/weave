# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import synthesis

import
  ./datatypes/[sync_types, context_thread_local,
               sparsesets, binary_worker_trees],
  ./contexts, ./config,
  ./instrumentation/[contracts, profilers, loggers],
  ./thieves,
  ./signals, ./targets

# Victims & Thiefs - Finite Automaton rewrite
# ----------------------------------------------------------------------------------
# This file is temporary and is used to make
# progressive refactoring of the codebase to
# finite state machine code.

type DeclineState = enum
  DS_ReceivedReq
  # Relaying a steal request
  DS_FindVictimAndSteal
  # Received own request
  DS_MyOwnReq
  DS_TreeIdle
  DS_ParkOrTerminate

type DS_Event = enum
  DSE_IamThief
  DSE_IamNewVictim
  DSE_MyTreeIsIdle
  DSE_ItWasTheLastReq
  DSE_IamLeader

declareAutomaton(declineReqFSA, DeclineState, DS_Event)

setPrologue(declineReqFSA):
  ## Pass steal request to another worker
  ## or the manager if it's our own that came back
  preCondition: req.retry <= WV_MaxRetriesPerSteal

  req.retry += 1
  incCounter(stealDeclined)

  profile_start(send_recv_req)

setEpilogue(declineReqFSA):
  profile_stop(send_recv_req)

setInitialState(declineReqFSA, DS_ReceivedReq)
setTerminalState(declineReqFSA, DS_Exit)

# -------------------------------------------

implEvent(declineReqFSA, DSE_IamThief):
  req.thiefID == myID()

behavior(declineReqFSA):
  ini: DS_ReceivedReq
  event: DSE_IamThief
  transition: discard
  fin: DS_MyOwnReq

behavior(declineReqFSA):
  ini: DS_ReceivedReq
  transition: discard
  fin: DS_FindVictimAndSteal

# Decline other steal requests
# -------------------------------------------

onEntry(declineReqFSA, DS_FindVictimAndSteal):
  req.victims.excl(myID())
  let target = findVictim(req)

implEvent(declineReqFSA, DSE_IamNewVictim):
  target == myID()

behavior(declineReqFSA):
  ini: DS_FindVictimAndSteal
  event: DSE_IamNewVictim
  transition:
    # A worker may receive its own steal request in "Working" state
    # in that case, it's a signal to call "lastAttemptFailure"/defer to "declineOwn"
    # but with termination detection.
    # but is it safe? in any case, we need to forget it to prevent a livelock
    # where a worker constantly retrieves its own steal request from one of its child channels
    # see: https://github.com/mratsim/weave/issues/43
    # Also victims.nim imports thieves.nim so we can't import victims.declineOwn here. (outdated comment)
    ascertain: req.state == Working
    forget(req)
  fin: DS_Exit

behavior(declineReqFSA):
  ini: DS_FindVictimAndSteal
  transition:
    # debug: log("Worker %2d: relay steal request from %d to %d (Channel 0x%.08x)\n",
    #   myID(), req.thiefID, target, globalCtx.com.thefts[target].addr)
    target.relaySteal(req)
  fin: DS_Exit

# Decline your own steal request
# -------------------------------------------

onEntry(declineReqFSA, DS_TreeIdle):
  # debug:
  #   log("Worker %2d: received own request (req.state: %s, left (%d): %s, right (%d): %s)\n",
  #     myID(), $req.state,
  #     myWorker().left,
  #     if myWorker().leftIsWaiting: "waiting" else: "not waiting",
  #     myWorker().right,
  #     if myWorker().rightIsWaiting: "waiting" else: "not waiting")
  discard

implEvent(declineReqFSA, DSE_MyTreeIsIdle):
  req.state == Stealing and myWorker().leftIsWaiting and myWorker().rightIsWaiting

behavior(declineReqFSA):
  ini: DS_MyOwnReq
  event: DSE_MyTreeIsIdle
  transition: discard
  fin: DS_TreeIdle

behavior(declineReqFSA):
  ini: DS_MyOwnReq
  transition:
    # Our own request but we still have work, so we reset it and recirculate.
    ascertain: req.victims.capacity.int32 == workforce()
    req.retry = 0
    req.victims.refill()
  fin: DS_FindVictimAndSteal

# -------------------------------------------

implEvent(declineReqFSA, DSE_ItWasTheLastReq):
  # When there is only one concurrent steal request allowed, it's always the last.
  when WV_MaxConcurrentStealPerWorker == 1:
    true
  else:
    myThefts().outstanding == WV_MaxConcurrentStealPerWorker and
      myTodoBoxes().len == WV_MaxConcurrentStealPerWorker - 1

behavior(declineReqFSA):
  ini: DS_TreeIdle
  event: DSE_ItWasTheLastReq
  transition:
    when WV_MaxConcurrentStealPerWorker > 1:
      # "WV_MaxConcurrentStealPerWorker - 1" steal requests have been dropped
      # as evidenced by the corresponding channel "address boxes" being recycled
      ascertain: myThefts().dropped == WV_MaxConcurrentStealPerWorker - 1
  fin: DS_ParkOrTerminate

behavior(declineReqFSA):
  ini: DS_TreeIdle
  transition:
    drop(req)
  fin: DS_Exit

# Last steal attempt is a failure
# -------------------------------------------

implEvent(declineReqFSA, DSE_IamLeader):
  myID() == LeaderID

behavior(declineReqFSA):
  ini: DS_ParkOrTerminate
  event: DSE_IamLeader
  transition:
    detectTermination()
    forget(req)
  fin: DS_Exit

behavior(declineReqFSA):
  ini: DS_ParkOrTerminate
  transition:
    req.state = Waiting
    debugTermination:
      log("Worker %2d: sends state passively WAITING to its parent worker %d\n", myID(), myWorker().parent)
    Backoff:
      myParking().prepareToPark()
    sendShare(req)
    ascertain: not myWorker().isWaiting
    myWorker().isWaiting = true
    Backoff: # Thread is blocked here until woken up.
      myParking().park()
  fin: DS_Exit

# -------------------------------------------

synthesize(declineReqFSA):
  proc decline*(req: sink StealRequest) {.gcsafe.}
