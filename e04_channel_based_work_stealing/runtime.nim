import
  # Standard library
  atomics,
  # Internal
  ./deque_list_tl, ./channel,
  ./bounded_stack,
  ./tasking_internal

# Thread-local task deque
var deque {.threadvar.} = DequeListTL

# Worker -> worker: intra-partition steal requests (MPSC)
var chan_requests: array[MaxWorkers, Channel]

# Worker -> worker: tasks (SPSC)
var chan_tasks: array[MaxWorkers, array[MaxSteal, Channel]]

# Every worker maintains a stack of (recycled) channels to
# keep track of which channels to use for the next steal requests
var channel_stack {.threadvar.}: BoundedStack[MaxSteal, Channel]

when defined(VictimCheck):
  # TODO - add to compilation flags
  type TaskIndicator = object
    tasks: Atomic[bool]
    padding: array[64 - sizeof(Atomic[bool]), byte]

  var task_indicators: array[MaxWorkers, TaskIndicator]

  template likely_has_tasks(id: int32): bool {.dirty.} =
    task_indicators[id].tasks.load(moRelaxed) > 0

  template have_tasks(id: int32) {.dirty.} =
    task_indicators[id].tasks.store(true, moRelaxed)

  template have_no_tasks(id: int32) {.dirty.} =
    task_indicators[id].tasks.store(false, moRelaxed)
