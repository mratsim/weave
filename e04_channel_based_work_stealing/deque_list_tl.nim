# A list-based thread-local work-stealing deque
# Tasks are stored in an unbounded doubly linked list

import
  # Internal
  ./task, ./task_stack

type
  DequeListTl = ptr DequeListTlObj
  DequeListTlObj = object
    head, tail: Task
    num_tasks: int32
    num_steals: int32
    # Pool of free task objects
    freelist: TaskStack

proc deque_list_tl_new(): DequeListTl =
  result = malloc(DequeListTlObj)
  if result.isNil:
    raise newException(OutOfMemError, "Could not allocate memory")

  let dummy = task_new()
  dummy.fn = cast[proc (param: pointer)](0xCAFE) # Easily assert things going wrong
  result.head = dummy
  result.tail = dummy
  result.num_tasks = 0
  result.num_steals = 0
  result.freelist = task_stack_new()
