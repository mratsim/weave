import
  # Internal
  ./primitives/c,
  ./task

# A stack of recently used Task objects (LIFO)
# ----------------------------------------------------------------------------------

type
  TaskStack = ptr TaskStackObj
  TaskStackObj = object
    top: Task

func task_stack_empty(stack: TaskStack): bool =
  assert not stack.isNil
  return stack.top.isNil

func task_stack_push(stack: TaskStack, task: sink Task) =
  assert not stack.isNil
  assert not task.isNil

  task.next = stack.top
  stack.top = task

func task_stack_pop(stack: TaskStack): Task =
  assert not stack.isNil
  if task_stack_empty(stack):
    return nil

  result = stack.top
  stack.top = stack.top.next
  result.next = nil

func task_stack_new(): TaskStack =
  # We consider that task_stack_new has no side-effect
  # i.e. it never fails
  #      and we don't care about pointer addresses
  result = malloc(TaskStackObj)
  if result.isNil:
    {.noSideEffect.}:
      # writeStackTrace()
      write(stderr, "Warning: task_stack_new failed\n")
    return

  result.top = nil

func task_stack_delete(stack: sink TaskStack) =
  if stack.isNil:
    return

  while (let task = task_stack_pop(stack); not task.isNil):
    ## We assume that all tasks are heap allocated
    free(task)

  assert(task_stack_empty(stack))
  free(stack)
