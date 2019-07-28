import
  atomics,
  ./lifo_allocator

# Constants
# ----------------------------------------------------------------------

const
  CacheLineSize = 64 # Some Samsung phone have 128 bytes cache line
                     # This is necessary to avoid cache invalidation / false sharing
                     # when many cores read/write in the same cache line


type
  # Tasking - internal
  # --------------------------------------------------------------------

  TaskDeque*[T] = ptr TaskDequeObj[T]
  TaskDequeObj[T] = object
    ## The owning worker pushes/pops tasks from the end
    ## of the deque (depth-first) to improve locality of tasks.
    ##
    ## The stealing workers pop tasks from the beginning
    ## of the deque (breadth-first) to improve parallelism
    ## and limit synchronization.
    m_mask: int
    m_array: ptr UncheckedArray[T]

    # Concurrent access
    # Need padding to a cache-line
    pad0: array[CacheLineSize-sizeof(int)-sizeof(pointer), byte]
    m_nstolen: Atomic[int]
    pad1: array[CacheLineSize-sizeof(int), byte]
    m_top: Atomic[int]
    pad2: array[CacheLineSize-sizeof(int), byte]
    m_bottom: Atomic[int]

# Task Deque
# ----------------------------------------------------------------------
# Correct and Efficient Work-Stealing for Weak Memory Models
# https://www.di.ens.fr/~zappa/readings/ppopp13.pdf

func newTaskDeque*(
        T: typedesc,
        size: int,
        allocator: ptr LifoAllocator
      ): TaskDeque[T] =
  assert size.isPowerOf2(), "size must be a power of 2"

  result = allocator.alloc(TaskDequeObj[T])

  result.mask = size-1
  result.m_array = allocator.alloc_array(T, size)
  result.m_next = nil
  result.m_nstolen = 0
  result.m_top = 1
  result.m_bottom = 1

func set_next(td, next: TaskDeque) {.inline.}=
  td.m_next = next

func get_next(td: TaskDeque): TaskDeque {.inline.}=
  return td.m_next

# Push
# ----------------------------------------------------------------------

func put_allocate[T](td: TaskDeque[T]): ptr T {.inline.}=
  let b = td.m_bottom.load(moRelaxed)
  return addr td.m_array[b and td.m_mask]

func put_commit(td: TaskDeque) =
  ## Append a task at the end of the deque
  let b = td.m_bottom.load(moRelaxed)
  # Barrier
  fence(moRelease)
  # Make task visible (and stealable only now)
  store(td.m_bottom, b+1, moRelaxed)

# Pop
# ----------------------------------------------------------------------

proc take*[T](td: TaskDeque[T], nstolen: var int): ptr T {.sideeffect.}=
  ## Retrieve a task from the end of the deque

  # Reserve task by decrementing last index
  let b = fetchSub(td.m_bottom, moRelaxed) - 1
  let t = load(td.m_top, moRelaxed)
  let n = load(td.m_nstolen, moRelaxed)

  if t > b:
    # Empty deque, restoring to empty state
    store(td.m_bottom, b+1)
    nstolen = n
    return nil

  if t == b:
    # We had 1 task left - try to reserve it by updating head
    if not compareExchange(td.m_top, t, t+1, moSequentiallyConsistent, moRelaxed):
      # Task was stolen
      td.m_bottom = b+1
      nstolen = n+1
      return nil

    # We won the race
    td.m_bottom = b+1
    return addr td.m_array[b and td.m_mask]

  # Task can't be stolen (more than 1 task in deque)
  return addr td.m_array[b and td.m_mask]

# Steal
# ----------------------------------------------------------------------

proc steal*[T](td: TaskDeque[T], was_empty: var bool): ptr T {.sideeffect.} =
  ## Thief: Retrieve a task from the start of another worker queue

  let t = load(td.m_top, moAcquire)
  fence(moSequentiallyConsistent)       # Ensure consistent view of the deque size
  let b = load(td.m_bottom, moAcquire)

  if t >= b:
    # Empty deque
    was_empty = true
    return nil

  # We optimistically steal
  result = addr td.m_array[t and td.m_mask]
  discard fetchAdd(td.numStolen, 1, moRelaxed)

  if not compareExchangeWeak(td.m_top, t, t+1, moSequentiallyConsistent, moRelaxed):
    # A weak cmpexch (that can fail on timing or cache line reload)
    # is fine for the thief.
    #
    # We were not stealing fast enough
    discard fetchSub(td.m_nstolen, 1, moRelaxed)
    return nil

func return_stolen(td: TaskDeque) {.inline.}=
  assert td.m_nstolen > 0, "No stolen task!"
  discard fetchSub(td.m_nstolen, 1, moRelaxed)
