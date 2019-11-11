# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./bounded_queues, ./sync_types, ./prell_deques,
  ../config,
  ../memory/intrusive_stacks,
  ../instrumentation/contracts

# Thread-local context
# ----------------------------------------------------------------------------------

type
  Worker* = object
    ## Distributed binary tree
    ##
    ## Each worker/thread is a node ID that will determine
    ## its parent and the children it oversees if any
    ##
    ## a node N will have as a left child node N*2+1
    ## and as a right child node N*2+2
    ##
    ## This tree tracks if workers backed off from stealing
    ## if they didn't find any task and now take a passive role:
    ## waiting for tasks to be shared instead of actively stealing.
    ##
    ## This is a "thread-local" structure, updates are received asynchronously
    ## via the StealRequest channel.

    # ⚠️ : We use 0-based indexing if you are familiar with binary tree
    #      indexed from 1, this is the correspondance table
    #                  root at 0    root at 1
    # Left child        ix*2 + 1     ix*2
    # Right child       ix*2 + 2     ix*2 + 1
    # Parent            (ix-1)/2     ix/2
    ID*: WorkerID
    left*: WorkerID
    right*: WorkerID
    parent*: WorkerID
    workSharingRequests*: BoundedQueue[2, StealRequest]
    deque*: PrellDeque[Task]
    currentTask*: Task
    leftIsWaiting*: bool
    rightIsWaiting*: bool
    isWaiting*: bool

  Thefts* = object
    ## Thief state
    # Outstanding steal requests [0, MaxSteal]
    outstanding*: int
    # Before a worker can become quiescent it has to drop MaxSteal - 1
    # steal request and send the remaining one to its parent
    dropped*: int
    # RRNG state to choose victims
    rng*: uint32
    when defined(StealLastVictim):
      lastVictim*: WorkerID
    when defined(StealLastThief):
      lastThief*: WorkerID
    # Adaptative theft
    stealHalf*: bool
    recentTasks*: int
    recentSteals*: int

  TLContext* = object
    ## Thread-Local context
    worker*: Worker
    thefts*: Thefts
    taskCache*: IntrusiveStack[Task]
    # Leader thread only - Whole runtime is quiescent
    runtimeIsQuiescent*: bool
    when defined(PI_Metrics):
      counters*: Counters

  Counters* = object
    tasksExec: int
    tasksSent: int
    tasksSplit: int
    stealSent: int
    stealHandled: int
    stealDeclined: int
    shareSent: int
    shareHandled: int
    when defined(PI_StealBackoff):
      stealResent: int
    when StealStrategy == StealKind.adaptative:
      stealOne: int
      stealHalf: int
      shareOne: int
      shareHalf: int
    when defined(PicassoLazyFutures):
      futuresConverted: int
    randomReceiverCalls: int
    randomReceiverEarlyExits: int

# Worker proc
# ----------------------------------------------------------------------------------

func left*(ID, maxID: WorkerID): WorkerID {.inline.} =
  preCondition: ID >= 0 and maxID >= 0
  preCondition: ID <= maxID

  result = 2*ID + 1
  if result > maxID:
    result = -1

func right*(ID, maxID: WorkerID): WorkerID {.inline.} =
  preCondition: ID >= 0 and maxID >= 0
  preCondition: ID <= maxID

  result = 2*ID + 2
  if result > maxID:
    result = -1

func parent(ID: WorkerID): int32 {.inline.} =
  (ID - 1) shr 1

func initialize*(w: var Worker, ID, maxID: WorkerID) {.inline.} =
  w.left = left(ID, maxID)
  w.right = right(ID, maxID)
  w.parent = parent(ID)

  if w.left == -1:
    w.leftIsWaiting = true
  if w.right == -1:
    w.rightIsWaiting = true

# Counters
# ----------------------------------------------------------------------------------

template incCounter*(name: untyped{ident}, amount = 1) =
  bind name
  metrics:
    counters.name += amount

template decCounter*(name: untyped{ident}) =
  bind name
  metrics:
    counters.name -= 1
