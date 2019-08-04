type

  WorkerTree* = object
    left_child: int32
    right_child: int32
    parent: int32
    num_children: int32
    left_subtree_is_idle: bool
    right_subtree_is_idle: bool
    ## WHen a workerhas become quiescent and backs off from stealing
    ## after both subtree are idles
    ## it waits for tasks from its parent
    waiting_for_tasks: bool

func left_child*(ID, maxID: int32): int32 {.inline.} =
  assert(ID >= 0 and maxID >= 0)
  assert(ID <= maxID)

  result = 2*ID + 1
  if result > maxID:
    result = -1

func right_child*(ID, maxID: int32): int32 {.inline.} =
  assert(ID >= 0 and maxID >= 0)
  assert(ID <= maxID)

  result = 2*ID + 2
  if result > maxID:
    result = -1

func parent(ID: int32): int32 {.inline.} =
  assert(ID >= 0)

  (ID - 1) shr 1

proc worker_tree_init(tree: var WorkerTree, ID, maxID: int32) =
  # assert not tree.isNil
  assert ID >= 0 and maxID >= 0
  assert ID <= maxID

  tree.left_child = left_child(ID, maxID)
  tree.right_child = right_child(ID, maxID)
  tree.parent = parent(ID)

  tree.num_children = 0
  tree.left_subtree_is_idle = false
  tree.right_subtree_is_idle = false
  tree.waiting_for_tasks = false

  if tree.left_child != -1:
    inc tree.num_children
  else: # Reached end
    tree.left_subtree_is_idle = true

  if tree.right_child != -1:
    inc tree.num_children
  else: # Reached end
    tree.right_subtree_is_idle = true

  # Sanity checks
  assert(tree.left_child != ID and tree.right_child != ID)
  assert(0 <= tree.num_children and tree.num_children <= 2)
  assert((tree.parent == -1 and ID == 0) or (tree.parent >= 0 and ID > 0))
