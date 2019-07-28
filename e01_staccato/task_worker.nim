# We keep both task and worker in the same module
# to avoid recursive module imports

# We also define all the proc in this module
# to be able to keep fields private

import
  # Standard library
  atomics, random,
  # Internal
  ./task_deque, ./lifo_allocator,
  ./threading_primitives

type
  # Tasking - user-facing
  # --------------------------------------------------------------------

  Task*[T] = object of RootObj
    ## User tasks inherit from this.
    ## Highly-experimental, inheritance from value types
    ## might blow in your face.
    ##
    ## Plus user task is recursive:
    ## type ComputePiTask = object of Task[ComputePiTask]
    m_worker: Worker[T]
    m_tail: TaskDeque[T]
    execute*: proc()

  # Worker - internal
  # --------------------------------------------------------------------

  Worker*[T] = ptr WorkerObj[T]
  WorkerObj[T] = object
    m_id: int
    m_taskgraph_degree: int
    m_taskgraph_height: int
    m_allocator: LifoAllocator

    m_stopped: Atomic[bool]

    m_nvictims: Atomic[int]
    m_nvictims_heads: ptr UncheckedArray[TaskDeque[T]]

    m_head_deque: TaskDeque[T]

# Task
# --------------------------------------------------------------------

proc process(task: var Task, worker: Worker, deque: TaskDeque) =

  task.worker = worker
  task.deque = deque

  task.execute()

func child[T](task: Task[T]): ptr T =
  return task.m_tail.put_allocate()

func spawn[T](task: Task[T], t: T) =
  # t is unused
  task.m_tail.put_commit()

proc wait(task: Task) =
  task.m_worker.local_loop(task.m_tail)

# Worker
# ----------------------------------------------------------------------

proc newWorker*(
       T: typedesc,
       id: int, allocator: LifoAllocator, nvictims: int,
       taskgraph_degree, taskgraph_height: int
     ): Worker[T] =

  result = allocator.alloc(WorkerObj[T])

  result.m_id = id
  result.m_taskgraph_degree = taskgraph_degree
  result.m_taskgraph_height = taskgraph_height
  result.m_allocator = allocator
  result.m_stopped = false
  result.m_nvictims = 0


  result.m_victims_heads = allocator.alloc_array(TaskDeque[T], nvictims)

  var d = newTaskDeque(T, taskgraph_degree, allocator)
  result.m_head_deque = d

  for i in 1 .. taskgraph_height:
    let n = newTaskDeque(T, taskgraph_degree, allocator)
    d.set_next(n)
    d = n

proc `=destroy`[T](w: var WorkerObj[T]) =
  assert not w.m_allocator.isNil
  `=destroy`(w.m_allocator[])

func cache_victim(w: Worker, victim: Worker) =
  w.m_victims_heads[w.m_nvictims] = victim.m_head_deque
  inc w.m_nvictims

func stop(w: Worker) =
  w.m_stopped = true

proc grow_tail[T](w: Worker[T], tail: TaskDeque[T]) =
  if not tail.get_next().isNil:
    # Can only grow if last
    return

  tail.next = newTaskDeque(T, w.taskgraph_degree, w.m_allocator)

proc get_victim(w: Worker): TaskDeque =
  # don't start at 0
  # And use a different seed per thread
  var rng {.threadvar.} = randomize(w.id + 1000)
  let i = rng.rand(w.m_nvictims - 1)

  result = w.m_victims_heads[i]

proc steal_loop(w: Worker) =
  while w.m_nvictims == 0:
    threadYield()

  let vhead = w.get_victim()
  var vtail = vhead
  var now_stolen = 0

  while not load(w.stopped, moRelaxed):
    if now_stolen >= w.taskgraphDegree - 1:
      if not vtail.get_next().isNil:
        vtail = vtail.get_next()
        now_stolen = 0

    var was_empty = false
    let t = vtail.steal(was_empty)

    if not t.isNil:
      t.process(w, w.headDeque)
      vtail.return_stolen()

      # Continue to steal while we have tasks to steal
      vtail = w.get_victim()
      nowStolen = 0
      continue

    if not was_empty:
      # Deque was not empty but we didn't
      # get a task (because someone processed it under our nose)
      inc now_stolen
      continue

    if not vtail.get_next().isNil:
      vtail = vtail.get_next()
    else:
      vtail = w.get_vitctim()

    now_stolen = 0

proc steal_task[T](w: Worker[T], thief: TaskDeque[T], victim: var TaskDeque[T]): ptr Task[T] =
  if load(w.m_nvictims, moRelaxed) == 0:
    return nil

  let vhead = w.get_victim()
  var vtail = vhead
  var nowStolen = 0

  while true:
    if nowStolen >= w.taskgraphDegree - 1:
      if not vtail.get_next().isNil:
        vtail = vtail.get_next()
        nowStolen = 0

    var was_empty = false
    let t = vtail.steal(was_empty)

    if not t.isNil:
      victim = vtail
      return t

    if not was_empty:
      # Deque was not empty but we didn't
      # get a task (because someone processed it under our nose)
      inc now_stolen
      continue

    if not vtail.get_next().isNil:
      vtail = vtail.get_next()
    else:
      return nil

    now_stolen = 0

proc local_loop[T](w: Worker[T], tail: TaskDeque[T]) =
  var t: ptr T
  var victim: TaskDeque[T]

  while true: # Loop over local tasks
    if not t.isNil:
      w.grow_tail(tail)
      t.process(w, tail.get_next())

      if not victim.isNil:
        victim.return_stolen()
        victim = nil

    var nstolen = 0
    t = tail.take(nstolen)

    if not t.isNil:
      # Found a task, process it
      continue
    if nstolen == 0:
      # Found no task and no-one stole --> nothing to do
      return

    # Found no task because we were not fast enough
    # Try stealing
    t = steal_task(tail, victim)

    if t.isNil:
      # Nothing to steal, pass our turn
      thread_yield()

func root_allocate[T](w: Worker[T]): ptr T =
  return w.m_head_deque.put_allocate()

func root_commit(w: Worker) =
  return w.m_head_deque.put_commit()

proc root_wait(w: Worker) =
  local_loop(w.m_head_deque)
