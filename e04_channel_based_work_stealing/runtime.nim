import
  # Standard library
  atomics,
  # Internal
  ./deque_list_tl, ./channel,
  ./bounded_stack,
  ./tasking_internal,
  ./platform, ./bitfield

const MaxSteal {.intdefine.} = 1
  ## TODO add to compile-time flags

# Thread-local task deque
var deque {.threadvar.}: DequeListTL

# Worker -> worker: intra-partition steal requests (MPSC)
var chan_requests: array[MaxWorkers, Channel]

# Worker -> worker: tasks (SPSC)
var chan_tasks: array[MaxWorkers, array[MaxSteal, Channel]]

# Every worker maintains a stack of (recycled) channels to
# keep track of which channels to use for the next steal requests
var channel_stack {.threadvar.}: BoundedStack[MaxSteal, Channel]

proc channel_push(chan: sink Channel) {.inline.} =
  channel_stack.bounded_stack_push(chan)

proc channel_pop(): Channel {.inline.} =
  channel_stack.bounded_stack_pop()

when defined(VictimCheck):
  # TODO - add to compilation flags
  type TaskIndicator = object
    tasks: Atomic[bool]
    padding: array[64 - sizeof(Atomic[bool]), byte]

  var task_indicators: array[MaxWorkers, TaskIndicator]

  template likely_has_tasks(id: int32): bool {.dirty.} =
    task_indicators[id].tasks.load(moRelaxed) > 0

  template have_tasks() {.dirty.} =
    task_indicators[id].tasks.store(true, moRelaxed)

  template have_no_tasks() {.dirty.} =
    task_indicators[id].tasks.store(false, moRelaxed)

else:
  template likely_has_tasks(id: int32): bool =
    true

  template have_tasks() {.dirty.} =
    discard

  template have_no_tasks() {.dirty.} =
    discard


# When a steal request is returned to its sender after MAX_STEAL_ATTEMPTS
# unsuccessful attempts, the steal request changes state to STATE_FAILED and
# is then passed on to tree.parent as a work sharing request: the parent holds
# on to this request until it can send tasks in return. Thus, when a worker
# receives a steal request whose state is STATE_FAILED, the sender is either
# tree.left_child or tree.right_child. At this point, there is a "lifeline"
# between parent and child: the child will not send further steal requests
# until it receives new work from its parent. We have switched from work
# stealing to work sharing. This also means that backing off from work
# stealing by withdrawing a steal request for a short while is no longer
# needed, as steal requests are withdrawn automatically.
#
# Termination occurs once worker 0 detects that both left and right subtrees
# of workers are idle and worker 0 is itself idle.
#
# When a worker receives new work, it must check its "lifelines" (queue of
# work sharing requests) and try to distribute as many tasks as possible,
# thereby reactivating workers further down in the tree.

type
  WorkerState = enum
    ## Steal requests carry one of the following states:
    ## - STATE_WORKING means the requesting worker is (likely) still busy
    ## - STATE_IDLE means the requesting worker has run out of tasks
    ## - STATE_FAILED means the requesting worker backs off and waits for tasks
    ##   from its parent worker
    Working
    Idle
    Failed

  StealRequest = object
    chan: Channel             # Channel for sending tasks
    id: int32                 # ID of requesting worker
    retry: int32              # 0 <= tries <= num_workers_rt
    partition: int32          # partition in which the steal request was initiated
    pID: int32                # ID of requesting worker within partition
    victims: Bitfield[uint32] # Bitfield of potential victims
    state: WorkerState        # State of steal request and by extension requestion worker
    when StealStrategy == StealKind.adaptative:
      stealhalf: bool
      pad: array[2, byte]
    else:
      pad: array[3, byte]

template init_victims(): untyped =
  # `my_partition`: thread-local from partition.nim after running `partition_init`
  initBitfieldSetUpTo(uint32, my_partition.num_workers_rt)

template steal_request_init(): StealRequest =
  when StealStrategy == StealKind.adaptative:
    StealRequest(
      chan: channel_pop(),
      id: ID, # thread-local var from tasking_internal.ni
      retry: 0,
      partition: my_partition.number, # `my_partition`: thread-local from partition.nim after running `partition_init`
      pID: pID, # thread-local from runtime.nim, defined later
      victims: init_victims(),
      state: Working,
      stealhalf: stealhalf # thread-local from runtime.nim, defined later
    )
  else:
    StealRequest(
      chan: channel_pop(),
      id: ID, # thread-local var from tasking_internal.ni
      retry: 0,
      partition: my_partition.number, # `my_partition`: thread-local from partition.nim after running `partition_init`
      pID: pID, # thread-local from runtime.nim, defined later
      victims: init_victims(),
      state: Working
    )
