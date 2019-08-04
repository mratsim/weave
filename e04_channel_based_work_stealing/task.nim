import
  # Internal
  ./primitives/c

# Task
# ----------------------------------------------------------------------------------

const
  TaskDataSize = 192 - 96

type
  Task* = ptr TaskObj
  TaskObj = object
    # We save memory by using int32 instead of int
    # We also keep the original "future" name
    # It will be changed to FlowVar in the future for async compat
    parent*: Task
    prev*: Task
    next*: Task
    fn*: proc (param: pointer) {.nimcall.} # nimcall / closure?
    batch*: int32
    victim*: int32
    start*: int
    cur: int
    stop*: int
    chunks: int
    sst: int
    is_loop*: bool
    has_future: bool
    # List of futures required by the current task
    futures: pointer
    # User data
    data*: array[TaskDataSize, byte]

static: assert sizeof(TaskObj) == 192,
          "TaskObj is of size " & $sizeof(TaskObj) &
          " instead of the expected 192 bytes."


func task_zero*(task: sink Task): Task {.inline.} =
  zeroMem(task, sizeof(TaskObj))
  return task

func task_new*(): Task {.inline.} =
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

func task_delete*(task: sink Task) {.inline.} =
  free(task)

func task_data*(task: Task): ptr array[TaskDataSize, byte] {.inline.} =
  task.data.addr

# Private memory (PRM) task queue
# Circular doubly-linked list
# ----------------------------------------------------------------------------------

# TODO: currently unused

# Smoke test
# --------------------------------------------------

when isMainModule:
  let x = task_new()
