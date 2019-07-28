when not compileOption("threads"):
    {.error: "This requires --threads:on compilation flag".}

import
  # Standard library
  std/atomics, std/bitops, std/cpuinfo,
  # Internal
  ./task_worker, ./lifo_allocator,
  ./threading_primitives

type
  Weaver[T] = object
    thr: Thread[void]
    allocator: LifoAllocator
    wkr: Worker[T]
    ready: Atomic[bool]

  Scheduler[T] = object
    m_taskgraph_degree: int
    m_taskgraph_height: int

    m_nworkers: int           # not needed we could use m_workers.len
    m_workers: seq[Weaver[T]] # no GC with newRuntime
    m_master: ptr Worker[T]

# Utils
# ----------------------------------------------------------------------

func nextPowerOf2(x: int): int =
  ## Returns x if x is a power of 2
  ## or the next biggest power of 2
  1 shl (fastLog2(x-1) + 1)

# Scheduler
# ----------------------------------------------------------------------

func predict_page_size[T](s: Scheduler[T]): int =
  result = alignof(TaskDeque[T]) + sizeof(TaskDeque[T])
  result += alignof(T) + sizeof(T) * s.m_taskgraph_degree
  result *= s.m_taskgraph_height

proc create_worker[T](s: var Scheduler[T], id: int) =
  let allocator = newLifoAllocator(s.predict_page_size())
  let wkr = newWorker(
    T, id, allocator,
    s.m_nworkers, s.m_taskgraph_degree, s.m_taskgraph_height
  )

  s.m_workers[id].allocator = allocator
  s.m_workers[id].wkr = wkr
  s.m_workers[id].ready = true

proc create_workers[T](s: var Scheduler[T]) =

  s.m_workers = newSeq[Weaver[T]](s.m_nworkers)

  s.create_worker(0)
  s.m_master = s.m_workers[0].wkr

  for i in 1 ..< s.m_nworkers:
    createThread(
      s.m_workers[i].thr,
      proc() =
        s.create_worker(i)
        s.m_workers[i].wkr.steal_loop()
    )

  for i in 0 ..< s.m_nworkers:
    while not s.m_workers[i].ready:
      thread_yield()

  for i in 0 ..< s.m_nworkers:
    for j in 0 ..< s.m_nworkers:
      if i == j:
        continue
      s.m_workers[i].wkr.cache_victim(s.m_workers[j].wkr)

proc initScheduler(T: typedesc,
                   taskgraph_degree: int,
                   taskgraph_height: int,
                   nworkers = 0): Scheduler[T] =
  result.m_taskgraph_degree = nextPowerOf2(taskgraph_degree)
  result.m_taskgraph_height = taskgraph_height

  if nworkers == 0:
    result.nworkers = countProcessors()
  else:
    result.nworkers = nworkers

  # TODO: handle countProcessors == 0
  result.create_workers()

proc `=destroy`[T](s: var Scheduler[T]) =
  for i in 1 ..< s.m_nworkers:
    while not s.m_workers[i].ready:
      thread_yield()

    s.m_workers[i].wkr.stop()

  for i in 1 ..< s.m_nworkers:
    # TODO: windows can wait for multiple objects with WaitForMultipleObjects
    s.mworkers[i].thr.joinThread()

  for i in 0 ..< s.m_nworkers:
    `=destroy`(s.m_workers[i].allocator[])
    # TODO: nim threads have no destructors ...

func root[T](s: Scheduler[T]): ptr T {.inline.} =
  s.m_master.root_allocate()

func spawn[T](s: Scheduler[T], task: ptr T) =
  s.m_master.root_commit()

func wait(s: Scheduler) =
  s.m_master.root_wait()
