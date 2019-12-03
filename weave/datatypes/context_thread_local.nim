# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./bounded_queues, ./sync_types, ./prell_deques,
  ../config,
  ../memory/[lookaside_lists, persistacks, allocs],
  ../instrumentation/contracts,
  ../random/rng,
  std/bitops

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
    outstanding*: range[int32(0)..int32(WV_MaxConcurrentStealPerWorker + 1)]
    # Before a worker can become quiescent it has to drop MaxSteal - 1
    # steal request and send the remaining one to its parent
    dropped*: int32
    # RRNG state to choose victims
    rng*: RngState
    when defined(StealLastVictim):
      lastVictim*: WorkerID
    when defined(StealLastThief):
      lastThief*: WorkerID
    # Adaptative theft
    stealHalf*: bool
    recentTasks*: int32
    recentThefts*: int32

  TLContext* = object
    ## Thread-Local context
    worker*: Worker
    thefts*: Thefts
    taskCache*: LookAsideList[Task]
    stealCache*: Persistack[WV_MaxConcurrentStealPerWorker, deref(StealRequest)]
    # Leader thread only - Whole runtime is quiescent
    runtimeIsQuiescent*: bool
    when defined(WV_Metrics):
      counters*: Counters
    signaledTerminate*: bool

  Counters* = object
    tasksExec*: int
    tasksSent*: int
    tasksSplit*: int
    stealSent*: int
    stealHandled*: int
    stealDeclined*: int
    shareSent*: int
    shareHandled*: int
    when defined(WV_StealBackoff):
      stealResent*: int
    when StealStrategy == StealKind.adaptative:
      stealOne*: int
      stealHalf*: int
      shareOne*: int
      shareHalf*: int
    when defined(WV_LazyFlowvar):
      futuresConverted*: int
    randomVictimCalls*: int
    randomVictimEarlyExits*: int

# Worker proc
# ----------------------------------------------------------------------------------

# Workers form an implicit binary tree
#                  root at 0
# Left child        ix*2 + 1
# Right child       ix*2 + 2
# Parent            (ix-1)/2
#
# Representation
#
#  depth 0          ------ 0 ------
#  depth 1      -- 1 --       --- 2 ---
#  depth 2      3     4       5       6
#  depth 3    7  8  9  10  11  12  13  14
#
# In an array storage is linear
#
# 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14

func left(ID, maxID: WorkerID): WorkerID {.inline.} =
  preCondition: ID >= 0 and maxID >= 0
  preCondition: ID <= maxID

  result = 2*ID + 1
  if result > maxID:
    result = Not_a_worker

func right(ID, maxID: WorkerID): WorkerID {.inline.} =
  preCondition: ID >= 0 and maxID >= 0
  preCondition: ID <= maxID

  result = 2*ID + 2
  if result > maxID:
    result = Not_a_worker

func parent(ID: WorkerID): int32 {.inline.} =
  (ID - 1) shr 1

func initialize*(w: var Worker, maxID: WorkerID) {.inline.} =
  w.left = left(w.ID, maxID)
  w.right = right(w.ID, maxID)
  w.parent = parent(w.ID)

  if w.left == Not_a_worker:
    w.leftIsWaiting = true
  if w.right == Not_a_worker:
    w.rightIsWaiting = true

template isLeaf(node, maxID: int32): bool =
  node >= maxID div 2

func lastLeafOfSubTree(start, maxID: int32): int32 =
  ## Returns the last leaf of a sub tree
  # Algorithm:
  # we take the right side by doing
  # repeated (2n+2) computation until we reach the rightmost leaf node
  preCondition: start <= maxID
  result = start
  while not result.isLeaf(maxID):
    result = 2*result + 2

func prevPowerofTwo(n: int32): int32 {.inline.} =
  ## Returns n if n is a power of 2
  ## or the biggest power of 2 preceding n
  1'i32 shl fastLog2(n+1)

iterator traverseDepthFirst*(start, maxID: int32): int32 =
  ## CPU and memory efficient depth first iteration of implicit binary trees:
  ## Stackless and traversal can start from any subtrees

  # We use the integer bit representation as an encoding
  # to the binary tree path and use shifts and count trailing zero
  # to navigate downward and jump back to the parent

  preCondition: start in 0 .. maxID

  var depthIdx = start.prevPowerofTwo() # Index+1 of the first node of the current depth.
                                        # (2^depth - 1) is the index of starter node at each depth.
  var relPos = start - depthIdx + 1     # Relative position compared to the first node at that depth.


  # A node has coordinates (Depth, Pos) in the tree
  # with Pos: relative position to the start node of that depth
  #
  # node(Depth, Pos) = 2^Depth + Pos - 1
  #
  # In the actual code
  # depthIdx = 2^Depth and relPos = Pos

  preCondition: start == depthIdx + relPos - 1

  let lastLeaf = lastLeafOfSubTree(start, maxID)
  var node: int32

  while true:
    node = depthIdx + relPos - 1
    yield node
    if node == lastLeaf:
      break
    if node.isLeaf(maxId):
      relPos += 1
      let jump = countTrailingZeroBits(relPos)
      depthIdx = depthIdx shr jump
      relPos = relPos shr jump
    else:
      depthIdx = depthIdx shl 1
      relPos = relPos shl 1

# Sanity check
# ----------------------------------------------------------------------------------

#  depth 0          ------ 0 ------
#  depth 1      -- 1 --       --- 2 ---
#  depth 2      3     4       5       6
#  depth 3    7  8  9  10  11  12  13  14
#
# In an array storage is linear
#
# 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14

when isMainModule:
  let from0  = [ 0,  1,  3,  7,  8,  4,  9, 10, 2, 5, 11, 12, 6, 13, 14]
  let from1  = [ 1,  3,  7,  8,  4,  9, 10]
  let from2  = [ 2,  5, 11, 12,  6, 13, 14]
  let from3  = [ 3,  7,  8]
  let from4  = [ 4,  9, 10]
  let from5  = [ 5, 11, 12]
  let from6  = [ 6, 13, 14]
  let from7  = [ 7]
  let from8  = [ 8]
  let from9  = [ 9]
  let from10 = [10]
  let from11 = [11]
  let from12 = [12]
  let from13 = [13]
  let from14 = [14]

  template check(start: int, target: untyped) =
    var pos = 0
    for i in traverseDepthFirst(start, maxID = 14):
      doAssert: target[pos] == i
      pos += 1

    doAssert pos == target.len

  check(0, from0)
  check(1, from1)
  check(2, from2)
  check(3, from3)
  check(4, from4)
  check(5, from5)
  check(6, from6)
  check(7, from7)
  check(8, from8)
  check(9, from9)
  check(10,from10)
  check(11,from11)
  check(12,from12)
  check(13,from13)
  check(14,from14)
