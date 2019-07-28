import
  # Internal
  ./c_primitives

# Task
# ----------------------------------------------------------------------------------

const
  TaskDataSize = 192 - 96

  # User data should be aligned to 8 bytes
  # And Nim still doesn't allow to specify alignment :/
  # TODO - Question: Why? For pointer? Why not cache-line?
  Alignment = 8 # Must be power of 2
  Padding = block:
    var padding = 0
    padding += sizeof(pointer)               # parent
    padding += sizeof(pointer)               # prev
    padding += sizeof(pointer)               # next
    padding += sizeof(proc (param: pointer)) # fn
    padding += sizeof(int32)                 # batch
    padding += sizeof(int32)                 # victim
    padding += sizeof(int32)                 # start
    padding += sizeof(int32)                 # cur
    padding += sizeof(int32)                 # stop
    padding += sizeof(int32)                 # chunks
    padding += sizeof(int32)                 # sst
    padding += sizeof(bool)                  # is_loop
    padding += sizeof(bool)                  # has_future
    padding += sizeof(pointer)               # futures

    padding = Alignment - (padding and (Alignment-1))
    padding

type
  Task* = ptr TaskObj
  TaskObj = object
    # We save memory by using int32 instead of int
    # We also keep the original "future" name
    # It will be changed to FlowVar in the future for async compat
    parent: Task
    prev: Task
    next*: Task
    fn: proc (param: pointer)
    batch: int32
    victim: int32
    start: int32
    cur: int32
    stop: int32
    chunks: int32
    sst: int32
    is_loop: bool
    has_future: bool
    # List of futures required by the current task
    futures: pointer
    # Dummy padding data
    pad: array[Padding, byte]
    # User data
    data: array[TaskDataSize, byte]

func task_zero(task: sink Task): Task {.inline.} =
  reset(task[])
  return task

func task_new(): Task {.inline.} =
  # We consider that task_new has no side-effect
  # i.e. it never fails
  #      and we don't care about pointer addresses
  result = malloc(TaskObj)
  if result.isNil:
    {.noSideEffect.}:
      # writeStackTrace()
      write(stderr, "Warning: task_new failed\n")
    return

  result = task_zero(result)

func task_delete(task: sink Task) {.inline.} =
  free(task)

# Private memory (PRM) task queue
# Circular doubly-linked list
# ----------------------------------------------------------------------------------

# TODO: currently unused

# Smoke test
# --------------------------------------------------

when isMainModule:
  let x = task_new()
