# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./bounded_queues, ./sync_types, ./prell_deques, ./binary_worker_trees,
  ../config,
  ../memory/[lookaside_lists, persistacks, allocs, memory_pools],
  ../instrumentation/contracts,
  ../random/rng,
  ../cross_thread_com/scoped_barriers

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
    currentScope*: ptr ScopedBarrier
    leftIsWaiting*: bool
    rightIsWaiting*: bool
    isWaiting*: bool

  Thefts* = object
    ## Thief state
    # Outstanding steal requests [0, MaxSteal]
    outstanding*: range[int32(0)..int32(WV_MaxConcurrentStealPerWorker + 1)]
    # Before a worker can become quiescent it has to drop MaxSteal - 1
    # steal request and send the remaining one to its parent
    dropped*: int32
    # RNG state to choose victims
    rng*: RngState
    when FirstVictim == LastVictim:
      lastVictim*: WorkerID
    when FirstVictim == LastThief:
      lastThief*: WorkerID
    # Adaptative theft
    stealHalf*: bool
    recentTasks*: int32
    recentThefts*: int32

  WorkerContext* = object
    ## Thread-Local context for Weave workers
    worker*: Worker
    thefts*: Thefts
    taskCache*: LookAsideList[Task]
    stealCache*: Persistack[WV_MaxConcurrentStealPerWorker, deref(StealRequest)]
    # Root thread only - Whole runtime is quiescent
    runtimeIsQuiescent*: bool
    signaledTerminate*: bool
    when defined(WV_Metrics):
      counters*: Counters

  Counters* = object
    tasksExec*: int
    tasksSent*: int
    loopsSplit*: int
    loopsIterExec*: int
    stealSent*: int
    stealHandled*: int
    stealDeclined*: int
    shareSent*: int
    shareHandled*: int
    when StealStrategy == StealKind.adaptative:
      stealOne*: int
      stealHalf*: int
      shareOne*: int
      shareHalf*: int
    when WV_UseLazyFlowvar:
      futuresConverted*: int

  JobProviderContext* = object
    ## Thread-local context for non-Weave threads
    ## to allow them to submit jobs to Weave.
    mempool*: ptr TLPoolAllocator # TODO: have the main thread takeover the mempool on thread destruction

  ThreadKind* = enum
    Unknown
    WorkerThread
    SubmitterThread

# Worker proc
# ----------------------------------------------------------------------------------

func initialize*(w: var Worker, maxID: WorkerID) {.inline.} =
  w.left = left(w.ID, maxID)
  w.right = right(w.ID, maxID)
  w.parent = parent(w.ID)

  if w.left == Not_a_worker:
    w.leftIsWaiting = true
  else:
    w.leftIsWaiting = false
  if w.right == Not_a_worker:
    w.rightIsWaiting = true
  else:
    w.rightIsWaiting = false
