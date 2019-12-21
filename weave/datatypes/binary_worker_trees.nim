# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../instrumentation/contracts,
  std/bitops

# Worker
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
# In an array, storage is linear
#
# 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14

type
  WorkerID* = int32
  WorkerState* = enum
    ## Steal requests carry one of the following states:
    ## - Working means the requesting worker is (likely) still busy
    ##   but anticipating running out of tasks
    ## - Stealing means the requesting worker has run out of tasks
    ##   and is trying to steal some
    ## - Waiting means the requesting worker backs off and waits for tasks
    ##   from its parent worker
    Working
    Stealing
    Waiting

const Not_a_worker* = -1

# Worker initialization helpers
# ----------------------------------------------------------------------------------

func left*(ID, maxID: WorkerID): WorkerID {.inline.} =
  preCondition: ID >= 0 and maxID >= 0
  preCondition: ID <= maxID

  result = 2*ID + 1
  if result > maxID:
    result = Not_a_worker

func right*(ID, maxID: WorkerID): WorkerID {.inline.} =
  preCondition: ID >= 0 and maxID >= 0
  preCondition: ID <= maxID

  result = 2*ID + 2
  if result > maxID:
    result = Not_a_worker

func parent*(ID: WorkerID): int32 {.inline.} =
  (ID - 1) shr 1

# Routines for traversing implicit binary array trees
# ----------------------------------------------------

template isLeaf(node, maxID: WorkerID): bool =
  2*node + 1 > maxID

func lastLeafOfSubTree(start, maxID: WorkerID): WorkerID =
  ## Returns the last leaf of a sub tree
  # Algorithm:
  # we take the right side by doing
  # repeated (2n+2) computation until we reach the rightmost leaf node
  preCondition: start <= maxID
  result = start
  while not result.isLeaf(maxID):
    result = 2*result + 2

func prevPowerofTwo(n: WorkerID): WorkerID {.inline.} =
  ## Returns n if n is a power of 2
  ## or the biggest power of 2 preceding n
  1'i32 shl fastLog2(n+1)

iterator traverseDepthFirst(start, maxID: WorkerID): WorkerID {.used.}=
  ## CPU and memory efficient depth first iteration of implicit binary array trees:
  ## - Stackless
  ## - O(1) space, O(n + log(n)) operations (log(n) to find the last leaf)
  ## - traversal can start from any subtrees

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
    if node <= maxID:
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

iterator traverseBreadthFirst*(start, maxID: WorkerID): WorkerID =
  ## CPU and memory efficient breadth-first iteration of implicit binary trees:
  ## - Queueless
  ## - O(1) space, O(n) operations
  ## - traversal can start from any subtrees

  preCondition: start in 0 .. maxID

  var
    levelStart = start # Index of the node starting the current depth
    levelEnd = start   # Index of the node ending the current depth
    pos = 0'i32        # Relative position compared to the current depth

  var node: int32

  while true:
    node = levelStart + pos
    if node > maxID:
      break
    yield node
    if node == levelEnd:
      levelStart = 2*levelStart + 1
      levelEnd = 2*levelEnd + 2
      pos = 0
    else:
      pos += 1

# Sanity checks
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
  # Depth-first
  # --------------------------------------------------------------------

  block:
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

    # ----------------------------------
    # Incomplete trees
    let incomplete3 =  [0, 1, 3, 2]
    let incomplete7 =  [0, 1, 3, 7, 4, 2, 5, 6]
    let incomplete8 =  [0, 1, 3, 7, 8, 4, 2, 5, 6]
    let incomplete9 =  [0, 1, 3, 7, 8, 4, 9, 2, 5, 6]
    let incomplete10 = [0, 1, 3, 7, 8, 4, 9, 10, 2, 5, 6]
    let incomplete11 = [0, 1, 3, 7, 8, 4, 9, 10, 2, 5, 11, 6]

    template checkI(start, maxID: int, target: untyped) =
      var pos = 0
      for i in traverseDepthFirst(start, maxID):
        doAssert: target[pos] == i
        pos += 1

      doAssert pos == target.len

    checkI(0, 3, incomplete3)
    checkI(0, 7, incomplete7)
    checkI(0, 8, incomplete8)
    checkI(0, 9, incomplete9)
    checkI(0, 10, incomplete10)
    checkI(0, 11, incomplete11)

  # Breadth-first
  # --------------------------------------------------------------------

  block:
    let from0 = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
    let from1 = [1, 3, 4, 7, 8, 9, 10]
    let from4 = [4, 9, 10]
    let from5 = [5, 11, 12]

    template check(start: int, target: untyped) =
      var pos = 0
      for i in traverseBreadthFirst(start, maxID = 14):
        doAssert: target[pos] == i
        pos += 1

      doAssert pos == target.len

    check(0, from0)
    check(1, from1)
    check(4, from4)
    check(5, from5)

    # ----------------------------------
    # Incomplete trees

    let incomplete8to35 = [8, 17, 18, 35]
    let incomplete5to35 = [5, 11, 12, 23, 24, 25, 26]

    template checkI(start, maxID: int, target: untyped) =
      var pos = 0
      for i in traverseBreadthFirst(start, maxID):
        doAssert: target[pos] == i
        pos += 1

      doAssert pos == target.len

    checkI(8, 35, incomplete8to35)
    checkI(5, 35, incomplete5to35)
