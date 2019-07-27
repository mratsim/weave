# 01 - port of staccato: https://github.com/rkuchumov/staccato
#
# Characteristics:
# - help-first / child-stealing
# - leapfrogging
# - Tasks stored as object instead of pointer or closure
#   - to limit memory fragmentation and cache misses
#   - avoid having to deallocate the pointer/closure
#
# Notes:
# - There is one scheduler per instantiated type.
#   This might oversubscribe the system if we schedule
#   something on float and another part on int

# when not compileOption("threads"):
#     {.error: "This requires --threads:on compilation flag".}

import
  atomics, options, random,
  ./threading_primitives

# Constants
# ----------------------------------------------------------------------

const
  PageAlignment = 1024
  CacheLineSize = 64 # Some Samsung phone have 128 bytes cache line
                     # This is necessary to avoid cache invalidation / false sharing
                     # when many cores read/write in the same cache line

# Types
# ----------------------------------------------------------------------

type

  # Memory
  # --------------------------------------------------------------------

  StackAllocator = object
    ## Pages are pushed and popped from the last of the stack.
    ## Note: on destruction, pages are deallocated from first to last.
    pageSize: int
    last: ptr Page
    first: ptr Page

  Page = object
    ## Metadata prepended to the Allocator pages
    ## Pages track the next page
    ## And works as a stack allocator within the page
    next: ptr Page
    freeSpace: int
    top: pointer    # pointer to the last of the stack
    bottom: pointer # pointer to the first of the stack

  # Tasking - internal
  # --------------------------------------------------------------------

  TaskDeque[T] = object
    ## The owning worker pushes/pops tasks from the end
    ## of the deque (depth-first) to improve locality of tasks.
    ##
    ## The stealing workers pop tasks from the beginning
    ## of the deque (breadth-first) to improve parallelism
    ## and limit synchronization.
    mask: int
    tasks: ptr UncheckedArray[T]

    # Concurrent access
    # Need padding to a cache-line
    pad0: array[CacheLineSize-sizeof(int)-sizeof(pointer), byte]
    numStolen: Atomic[int]
    pad1: array[CacheLineSize-sizeof(int), byte]
    first: Atomic[int]
    pad2: array[CacheLineSize-sizeof(int), byte]
    last: Atomic[int]

  # Tasking - user-facing
  # --------------------------------------------------------------------

  Task[T] = object of RootObj
    ## User tasks inherit from this.
    ## Highly-experimental, inheritance from value types
    ## might blow in your face.
    ##
    ## Plus user task is recursive:
    ## type ComputePiTask = object of Task[ComputePiTask]
    worker: ptr Worker[T]
    taskDeque: ptr TaskDeque[T]
    execute: proc()

  # Task = concept task, var mut_task
  #   task is object
  #   execute(mut_task) # Require an execute routine

  #   # Unfortunately we leak implementationd details with concepts
  #   task.worker is ptr Worker[task]
  #   task.deque is ptr TaskDeque[task]

  Worker[T] = object
    id: int
    allocator: ptr StackAllocator
    taskgraphDegree: int
    taskgraphHeight: int

    stopped: Atomic[bool]

    numVictims: Atomic[int]
    victimsHeads: ptr UncheckedArray[TaskDeque[T]]

    headDeque: ptr TaskDeque[T]

# Utils
# ----------------------------------------------------------------------

func isPowerOf2(n: int): bool =
  (n and (n-1)) == 0

func round_step_down*(x: Natural, step: static Natural): int {.inline.} =
  ## Round the input to the previous multiple of "step"
  when step.isPowerOf2():
    # Step is a power of 2. (If compiler cannot prove that x>0 it does not make the optim)
    result = x and not(step - 1)
  else:
    result = x - x mod step

func round_step_up*(x: Natural, step: static Natural): int {.inline.} =
  ## Round the input to the next multiple of "step"
  when step.isPowerOf2():
    # Step is a power of 2. (If compiler cannot prove that x>0 it does not make the optim)
    result = (x + step - 1) and not(step - 1)
  else:
    result = ((x + step - 1) div step) * step

# Memory
# ----------------------------------------------------------------------
# A Practical Solution to the Cactus Stack Problem
# http://chaoran.me/assets/pdf/ws-spaa16.pdf

proc posix_memalign(mem: var ptr Page, alignment, size: csize){.sideeffect,importc, header:"<stdlib.h>".}
proc free(mem: sink pointer){.sideeffect,importc, header:"<stdlib.h>".}

func initPage(mem: pointer, size: int): Page =
  result.freeSpace = size
  result.top = mem
  result.bottom = cast[pointer](cast[ByteAddress](mem) +% sizeof(Page))

func align(alignment: static[int], size: int, buffer: var pointer, space: var int): pointer =
  ## Tries to get ``size`` of storage with the specified ``alignment``
  ## from a ``buffer`` of ``space`` size
  ##
  ## ``alignment``: specified alignment
  ## ``size``: desired size
  ## ``buffer``: pointer to the buffer holding the storage
  ## ``space``: space of that buffer
  ##
  ## If the aligned storage fit the buffer, its pointer is updated
  ## to the first byte of aligned storage and space is reduced by the bytes
  ## used for alignment
  ##
  ## Returns either an aligned pointer in the passed buffer or nil if it fails.
  static: doAssert isPowerOf2(alignment), $alignment & " is not a power of 2"
  let
    address = cast[ByteAddress](buffer)
    aligned = (address - 1 + alignment) and -alignment
    offset = aligned - address
  if size + offset > space:
    return nil
  else:
    space -= offset
    buffer = cast[pointer](aligned)
    return aligned

func alloc(page: var Page, alignment: static[int], size: int): pointer =
  ## Allocate a memory buffer within a page
  ## Returns nil if allocation failed
  static: doAssert isPowerOf2(alignment), $alignment & " is not a power of 2"

  result = align(alignment, size, page.bottom, page.freeSpace)
  if result.isNil:
    return
  page.bottom = cast[pointer](cast[ByteAddress](page.bottom) +% size)
  page.freeSpace -= size

proc allocate_page(alignment: static[int], size: int): ptr Page =
  ## Allocate a page
  ## Create a page metadata object at the start of the page
  ## that manages the memory within

  # Posix memalign requires size to be a power of 2
  static: doAssert isPowerOf2(alignment), $alignment & " is not a power of 2"
  let sizeUp = round_step_up(size, alignment)
  posix_memalign(result, alignment, sizeUp)

  # TODO: __mingw_aligned_malloc and _aligned_malloc on Win32
  # Or just request OS pages with mmap

  # Initialize the page metadata
  result[] = initPage(result, sizeUp - sizeof(Page))

proc initStackAllocator(pageSize: int): StackAllocator =
  result.pageSize = pagesize
  result.first = allocate_page(PageAlignment, pageSize)
  result.last = result.first

proc `=destroy`(al: var StackAllocator) =
  var node = al.first
  while not node.isNil:
    let p = node
    node = node.next
    free(p)

proc grow(al: var StackAllocator, required_size: int) =
  let size = max(al.pageSize, required_size)
  let p = allocate_page(PageAlignment, size)

  al.last.next = p
  al.last = p

proc alloc(al: var StackAllocator, alignment: static[int], size: int): pointer =
  result = al.last.alloc(alignment, size)
  if not result.isNil:
    return

  # OOM in page
  al.grow(size)

  # Retry
  result = al.last.alloc(alignment, size)

  if result.isNil:
    # Give up - note that if this is not done in the master thread
    #           a thread-local GC needs to be allocated
    raise newException(OutOfMemError, "Unable to allocate memory")

proc alloc(al: var StackAllocator, T: typedesc): ptr T =
  result = al.alloc(alignof(T), sizeof(T))

proc allocArray(al: var StackAllocator, T: typedesc, length: int): ptr UncheckedArray[T] =
  result = al.alloc(alignof(T), sizeof(T) * length)

# Task Deque
# ----------------------------------------------------------------------
# Correct and Efficient Work-Stealing for Weak Memory Models
# https://www.di.ens.fr/~zappa/readings/ppopp13.pdf

func initTaskDeque[T](
       buffer: ptr (T or UncheckedArray[T]),
       size: int
      ): TaskDeque[T] =
  assert size.isPowerOf2(), "size must be a power of 2"
  result.mask = size-1
  result.tasks = cast[ptr UncheckedArray[T]](buffer)
  result.top = 1
  result.bottom = 1

proc push[T](td: var TaskDeque[T], task: sink T) {.sideeffect.}=
  ## Worker: Append a task at the end of the deque

  let tail = load(td.last, moRelaxed)
  td.tasks[tail and td.mask] = task

  # Barrier
  fence(moRelease)

  # Make task visible (and stealable only now)
  store(td.last, tail+1, moRelaxed)

proc pop[T](td: var TaskDeque[T]): Option[T] {.sideeffect.}=
  ## Worker: Retrieve a task from the end of the deque

  # Reserve task by decrementing last index
  let tail = fetchSub(td.last, moRelaxed) - 1
  let head = load(td.first, moRelaxed)
  let steals = load(td.numStolen, moRelaxed)

  if tail > head:
    # Empty deque, restoring to empty state
    store(td.last, tail+1)
    td.numStolen = steals
    return

  if tail == head:
    # We had 1 task left - try to reserve it by updating head
    if not compareExchange(td.first, head, head+1, moSequentiallyConsistent, moRelaxed):
      # Task was stolen
      td.last = tail+1
      td.numStolen = steals+1
      return

    # We won the race
    td.last = tail+1

  # We won or task can't be stolen (more than 1 task in deque)
  result = some(td.tasks[tail and td.mask])

proc steal[T](td: var TaskDeque[T]): Option[T] {.sideeffect.} =
  ## Thief: Retrieve a task from the start of another worker queue

  let head = load(td.first, moAcquire)
  fence(moSequentiallyConsistent)       # Ensure consistent view of the deque size
  let tail = load(td.last, moAcquire)

  if head >= tail:
    # Empty deque
    return

  # We optimistically steal
  result = some(td.tasks[td.first and td.mask])
  discard fetchAdd(td.numStolen, 1, moRelaxed)

  if not compareExchangeWeak(td.first, head, head+1, moSequentiallyConsistent, moRelaxed):
    # A weak cmpexch (that can fail on timing or cache line reload)
    # is fine for the thief.
    #
    # We were not stealing fast enough
    discard fetchSub(td.numStolen, 1, moRelaxed)
    return none

  return

# Task
# ----------------------------------------------------------------------

proc process(task: var Task, worker: ptr Worker, deque: TaskDeque) =

  task.worker = worker
  task.deque = deque.unsafeAddr

  task.execute()

# Worker
# ----------------------------------------------------------------------

proc initWorker(
       T: typedesc,
       id: int, allocator: ptr StackAllocator, numVictims: int,
       taskgraphDegree, taskgraphHeight: int
     ): Worker[T] =
  result.id = id
  result.taskgraphDegree = taskgraphDegree
  result.taskgraphHeight = taskgraphHeight
  result.allocator = allocator

  result.victimsHeads = allocator.allocArray(T, numVictims)

  let
    mem = allocator.alloc(TaskDeque[T])
    buf = allocator.allocArray(T, taskgraphDegree)
    td  = initTaskDeque(buf, taskgraphDegree)

  result.headDeque = td.unsafeAddr

  var w = td
  for i in 1 .. taskgraphHeight:
    let
      # init co-workers
      cmem = allocator.alloc(TaskDeque[T])
      cbuf = allocator.allocArray(T, taskgraphDegree)
      ctd  = initTaskDeque(cbuf, taskgraphDegree)

    w.next = cmem
    w = cmem

proc `=destroy`[T](w: var Worker[T]) =
  `=destroy`(w.allocator[])

proc cache_victim(w: var Worker, victim: Worker) =
  w.victimsHeads[w.numVictims] = victim.headDeque
  inc w.nimVictims

proc push[T](w: Worker[T], task: sink T) {.inline.}=
  w.headDeque.push(task)

proc extend[T](tail: var TaskDeque[T], w: Worker[T]) =

  if not tail.next.isNil:
    # Can only extend if last
    return

  let
    mem = w.allocator.alloc(TaskDeque[T])
    buf = w.allocator.allocArray(T, w.taskgraphDegree)
    td  = initTaskDeque(buf, w.taskgraphDegree)

  tail.next = td

proc getVictim[T](w: Worker[T]): var TaskDeque[T] =
  # don't start at 0
  # And use a different seed per thread
  var rng {.threadvar.} = randomize(w.id + 1000)
  let i = rng.rand(w.numVictims-1)

  return w.victimsHead[i]

proc stealLoop[T](w: Worker[T]) =
  while w.numVictims == 0:
    threadYield()

  var vtail = w.getVictim()
  var nowStolen = 0

  while not load(w.stopped, moRelaxed):
    if nowStolen >= w.taskgraphDegree - 1:
      if not vtail.next.isNil:
        vtail = vtail.next
        nowStolen = 0

    var t = steal(vtail)

    if t.isSome:
      t.unsafeGet().process(w, w.headDeque)
      assert w.numStolen > 0
      discard fetchSub(w.numStolen, 1, moRelaxed)

      # Continue to steal while we have tasks to steal
      vtail = w.getVictim()
      nowStolen = 0
      continue

    # TODO, Staccato has a case where there is no task return
    # but the dequeue was not empty: when the tentative stolen
    # task was actually pre-empted by another thread.
    # Strangely it increases "nowStolen" in that case.

    if not vtail.next.isNil:
      vtail = vtail.next
    else:
      vtail = w.getVictim()

    nowStolen = 0

# Tests
# ----------------------------------------------------------------------

when isMainModule:

  type ComputePiTask = object of Task[COmputePiTask]
    iterStart: int
    iterEnd: int

  var a: ComputePiTask
  a.iterEnd = 100

  echo a
