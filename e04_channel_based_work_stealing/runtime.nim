import
  # Standard library
  locks,
  # Internal
  ./deque_list_tl, ./channel,
  ./bounded_stack, ./bounded_queue,
  ./worker_tree,
  ./tasking_internal,
  ./partition, task,
  ./platform, ./bit,
  primitives/c,
  ./profile

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

  Channel[T] = channel.Channel[T]
    # Conflicts with system.nim default channels

  StealRequest = object
    chan: Channel[Task]       # Channel for sending tasks
    ID: int32                 # ID of requesting worker
    retry: int32              # 0 <= tries <= num_workers_rt
    partition: int32          # partition in which the steal request was initiated
    pID: int32                # ID of requesting worker within partition
    victims: uint32           # bitfield of potential victims (max 32)
    state: WorkerState        # State of steal request and by extension requestion worker
    when StealStrategy == StealKind.adaptative:
      stealhalf: bool
      pad: array[2, byte]
    else:
      pad: array[3, byte]

# -------------------------------------------------------------------

template log(args: varargs[untyped]): untyped =
  printf(args)
  flushFile(stdout)

const MaxSteal {.intdefine.} = 1
  # TODO add to compile-time flags

var deque {.threadvar.}: DequeListTL
  ## Thread-local task deque

var chan_requests: array[MaxWorkers, Channel[StealRequest]]
 ## Worker -> worker: intra-partition steal requests (MPSC)

var chan_tasks: array[MaxWorkers, array[MaxSteal, Channel[Task]]]
 ## Worker -> worker: tasks (SPSC)

var channel_stack {.threadvar.}: BoundedStack[MaxSteal, Channel[Task]]
 ## Every worker maintains a stack of (recycled) channels to
 ## keep track of which channels to use for the next steal requests

proc channel_push(chan: sink Channel[Task]) {.inline.} =
  channel_stack.bounded_stack_push(chan)

proc channel_pop(): Channel[Task] {.inline.} =
  channel_stack.bounded_stack_pop()

# -------------------------------------------------------------------

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

template init_victims(): untyped =
  # `my_partition`: thread-local from partition.nim after running `partition_init`
  0xFFFFFFFF'u32 and bit_mask_32(my_partition.num_workers_rt)

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
      ID: ID, # thread-local var from tasking_internal.ni
      retry: 0,
      partition: my_partition.number, # `my_partition`: thread-local from partition.nim after running `partition_init`
      pID: pID, # thread-local from runtime.nim, defined later
      victims: init_victims(),
      state: Working
    )

# -------------------------------------------------------------------

var work_sharing_requests{.threadvar.}: BoundedQueue[2, StealRequest]
  ## Every worker has a queue where it keeps the failed steal requests of its
  ## children until work can be shared.
  ## A worker has between 0 and 2 children.

proc enqueue_work_sharing_request(req: StealRequest) {.inline.} =
  bounded_queue_enqueue(work_sharing_requests, req)

proc dequeue_work_sharing_request(): owned StealRequest {.inline.} =
  bounded_queue_dequeue(work_sharing_requests)

proc next_work_sharing_request(): lent StealRequest {.inline.} =
  bounded_queue_head(work_sharing_requests)

var requested {.threadvar.}: int32
  ## A worker can have up to MAXSTEAL outstanding steal requests

var dropped_steal_requests {.threadvar.}: int32
  ## Before a worker can become quiescent, it has to drop MAXSTEAL-1
  ## steal requests and send the remaining one to its parent

var tree {.threadvar.}: WorkerTree
  ## Worker tree related information is collected in this struct

when defined(StealLastVictim):
  var last_victim {.threadvar.} = -1
when defined(StealLastThief):
  var last_thief {.threadvar.} = -1

var victims {.threadvar.}: ptr array[MaxWorkers, int32]
  # Not to be confused with victim bitfield

var pID {.threadvar.}: int32
  ## A worker has a unique ID within its partition
  ## 0 <= pID <= num_workers_rt

var print_mutex: Lock
initLock(print_mutex)

template lprintf(args: varargs[untyped]): untyped =
  ## Printf wrapped in a lock for multithreading consistency
  acquire(print_mutex)
  printf(args)
  flushFile(stdout)
  release(print_mutex)

# -------------------------------------------------------------------

proc print_victims(victims: uint32, ID: int32) =

  template victim(victims, n: untyped): untyped =
    if (victims and bit(n)) != 0: '1'
    else: '0'

  assert my_partition.num_workers_rt in 1..32

  acquire(print_mutex)
  printf("victims[%2d] = ", ID)

  for i in countdown(31, my_partition.num_workers_rt):
    stdout.write('.')

  for i in countdown(my_partition.num_workers_rt-1, 0):
    stdout.write victim(victims, i)

  stdout.write '\n'
  release(print_mutex)

proc init_victims(ID: int32) =
  ## Currently only needed to count the number of workers

  var j = 0

  # Get all available worker in my_partition
  for i in 0 ..< my_partition.num_workers:
    let worker = my_partition.workers[i]
    if worker < num_workers: # Global taken from WEAVE_NUM_THREADS in tasking_internals
      victims[j] = worker
      inc j
      inc my_partition.num_workers_rt

  Master log("Manager %2d: %d of %d workers available\n", ID,
             my_partition.num_workers_rt, my_partition.num_workers)

var seed {.threadvar.}: uint32

proc ws_init() =
  ## Initializes the context needed for work-stealing
  seed = ID.uint32 # Seed for thread-safe PRNG provided by Linux kernel
  init_victims(ID)

proc mark_as_idle(victims: var uint32, n: int32) =
  ## Requires -1 <= n < num_workers
  if n == -1:
    # Invalid worker ID (parent of root or out-of-bound child)
    return

  let maxID = my_partition.num_workers_rt - 1

  if n < num_workers:
    mark_as_idle(victims, left_child(n, maxID))
    mark_as_idle(victims, right_child(n, maxID))
    # Unset worker n
    victims = victims and not bit(n)

func rightmost_victim(victims: uint32, ID: int32): int32 =
  result = rightmost_one_bit_pos(victims)
  if result == ID:
    result = rightmost_one_bit_pos(zero_rightmost_one_bit(victims))

  {.noSideEffect.}:
    assert(
      # Victim found
      ((result in 0 ..< my_partition.num_workers_rt) and
      result != ID) or
      # No victim found
      result == -1
    )

var random_receiver_calls {.threadvar.}: int32
var random_receiver_early_exits {.threadvar.}: int32

proc random_victim(victims: uint32, ID: int32): int32 =
  ## Choose a random victim != ID from the list of potential victims

  inc random_receiver_calls
  inc random_receiver_early_exits

  # No eligible victim? Return message to sender
  if victims == 0:
    return -1

  template potential_victim(victims, n: untyped): untyped =
    victims and bit(n)

  # Try to choose a victim at random
  for i in 0 ..< 3:
    let victim = rand_r(seed) mod my_partition.num_workers_rt
    if potential_victim(victims, victim) != 0 and victim != ID:
      return victim

  # We didn't early exit, i.e. not enough potential victims
  # for completely randomized selection
  dec random_receiver_early_exits

  # Build the list of victims
  let num_victims = count_one_bits(victims)
  assert num_victims in 0 ..< my_partition.num_workers_rt

  # Length of array is upper-bounded by the number of workers but
  # num_victims is likely less than that or we would
  # have found a victim above
  #
  # Unfortunaly VLA (Variable-Length-Array) are only available in C99
  # So we emulate them with alloca.
  #
  # num_victims is probably quite low compared to num_workers
  # i.e. 2 victims for a 16-core CPU hence we save a lot of stack.
  #
  # Heap allocation would make the system allocator
  # a multithreaded bottleneck on fine-grained tasks
  #
  # var potential_victims = alloca(int32, num_victims)
  var potential_victims: array[MaxWorkers, int32]

  # Map potential_victims with real IDs
  block:
    var n = victims
    var i, j = 0'i32
    while n != 0:
      if potential_victim(n, 0) != 0:
        # Test first bit
        potential_victims[j] = i
        inc j
      inc i
      n = n shr 1

    assert j == num_victims

  let idx = rand_r(seed) mod num_victims
  result = potential_victims[idx]
  # log("Worker %d: rng %d, vict: %d\n", ID, rng, result)
  assert potential_victim(victims, result) != 0'u32

  assert(
    ((result in 0 ..< my_partition.num_workers_rt) and
    result != ID)
  )

# To profile different parts of the runtime
profile_decl(run_task)
profile_decl(enq_deq_task)
profile_decl(send_recv_task)
profile_decl(send_recv_req)
profile_decl(idle)

var
  requests_sent {.threadvar.}: int32
  requests_handled {.threadvar.}: int32
  requests_declined {.threadvar.}: int32
  tasks_sent {.threadvar.}: int32
  tasks_split {.threadvar.}: int32

when defined(LazyFutures):
  # TODO: add to compilation flags
  var futures_converted {.threadvar.}: int32

# -------------------------------------------------------------------

proc RT_init*() =
  ## Initialize the multithreading runtime

  # Small sanity checks
  # At this point, we have not yet decided who will be manager(s)
  assert is_manager == false # from partition.nim
  static:
    assert sizeof(StealRequest) == 32
    # assert sizeof(Task()[]) == 192 - checked in task.nim

  # TODO: following the global variables flow is very hard
  # This requires being called after `tasking_internal_init`
  assert num_workers > 0
  partition_assign_xlarge(MasterID)
  partition_set()
  assert not my_partition.isNil

  if is_manager:
    assert ID == MasterID

  deque = deque_list_tl_new()

  Master:
    # Unprocessed update message followed by new steal request
    # => up to two messages per worker (assuming MaxSteal == 1)
    chan_requests[ID] = channel_alloc(
      int32 sizeof(StealRequest), MaxSteal * num_workers * 2, Mpsc
    )
  Worker:
    chan_requests[ID] = channel_alloc(
      int32 sizeof(StealRequest), MaxSteal * num_workers, Mpsc
    )

  # At most MaxSteal steal requests and thus different channels
  channel_stack = bounded_stack_alloc(Channel[Task], MaxSteal)

  # Being able to send N steal requests requires either a single MPSC or
  # N SPSC channels
  for i in 0 ..< MaxSteal:
    chan_tasks[ID][i] = channel_alloc(int32 sizeof(Task), 1, Spsc)
    channel_push(chan_tasks[ID][i])

  assert channel_stack.top == MaxSteal

  victims = cast[ptr array[MaxWorkers, int32]](malloc(int32, MaxWorkers))

  ws_init()

  for i in 0 ..< my_partition.num_workers_rt:
    if ID == my_partition.workers[i]:
      pID = i
      break

  requested = 0

  when defined(VictimCheck):
    static: assert sizeof(TaskIndicator) == 64
    task_indicators[ID].tasks.store(false)

  # a worker has between zero and 2 children
  work_sharing_requests = bounded_queue_alloc(StealRequest, 2)

  # The worker tree is a complete binary tree with worker 0 at the root
  worker_tree_init(tree, ID, my_partition.num_workers_rt - 1)

  profile_init(run_task)
  profile_init(enq_deq_task)
  profile_init(send_recv_task)
  profile_init(send_recv_req)
  profile_init(idle)

proc RT_exit*() =
  deque_list_tl_delete(deque)
  free(victims)

  channel_free(chan_requests[ID])
  when ChannelCacheSize > 0:
    channel_cache_free()

  for i in 0 ..< MaxSteal:
    # No tasks left in channel
    assert channel_peek(chan_tasks[ID][i]) == 0
    channel_free(chan_tasks[ID][i])

  bounded_stack_free(channel_stack)
  bounded_queue_free(work_sharing_requests)

  partition_reset()

  log("Worker %d: random_receiver fast path (slow path): %3.0f %% (%3.0f %%)\n",
    ID, random_receiver_early_exits.float64 * 100 / random_receiver_calls.float64,
    100 - random_receiver_early_exits.float64 * 100 / random_receiver_calls.float64
  )

# -------------------------------------------------------------------

proc task_alloc*(): Task =
  deque_list_tl_task_new(deque)

when not defined(MaxStealAttempts):
  template MaxStealAttempts: int32 = my_partition.num_workers_rt - 1
    ## Number of steal attempts before a steal request is sent back to the thief
    ## Default value is the number of workers minus one

proc next_victim(req: var StealRequest): int32 =
  result = -1

  req.victims = req.victims and not bit(ID)

  template potential_victim(n: untyped): untyped {.dirty.}=
    req.victims and bit(n)

  if req.ID == ID:
    assert req.retry == 0
    # Initially: send message to random worker != ID
    result = rand_r(seed) mod my_partition.num_workers_rt
    while result == ID:
      result = rand_r(seed) mod my_partition.num_workers_rt
  elif req.retry == MaxStealAttempts:
    # Return steal request to thief
    # print_victims(req.victims, req.ID)
    result = req.ID
  else:
    # Forward steal reques to different worker != ID, if possible
    if tree.left_subtree_is_idle and tree.right_subtree_is_idle:
      mark_as_idle(req.victims, ID)
    elif tree.left_subtree_is_idle:
      mark_as_idle(req.victims, tree.left_child)
    elif tree.right_subtree_is_idle:
      mark_as_idle(req.victims, tree.right_child)
    assert potential_victim(ID) == 0
    result = random_victim(req.victims, req.ID)

  if result == -1:
    # Couldn't find victim; return steal request to thief
    assert req.victims == 0
    result = req.ID

  when false:
    if result == req.ID:
      log("%d -{%d}-> %d after %d tries (%u ones)\n",
        ID, req.ID, victim, req,retry, count_one_bits(req.victims)
      )

  assert result in 0 ..< my_partition.num_workers_rt
  assert result != ID
  assert req.retry in 0 ..< MaxStealAttempts

when defined(StealLastVictim) or defined(StealLastThief):
  proc steal_from(req: var StealRequest, worker: int32): int32 =
    if req.retry < MaxStealAttempts:
      if worker != -1 and worker != req.ID and likely_has_tasks(worker):
        return worker
      # Worker is unavailable, fallback to random victim selection
      return next_victim(req)
    return req.ID

# -------------------------------------------------------------------

# Forward declarations
proc try_send_steal_request(idle: bool)
# proc decline_steal_request(req: var StealRequest)
# proc decline_all_steal_requests()
proc split_loop(task: Task, req: sink StealRequest)

proc send_req(chan: Channel[StealRequest], req: sink StealRequest) {.inline.} =
  var nfail = 0
  while not channel_send(chan, req, int32 sizeof(req)):
    inc nfail
    if nfail mod 3 == 0:
      log("*** Worker %d: blocked on channel send\n", ID)
      # raising an exception in a thread will probably crash, oh well ...
      raise newException(DeadThreadError, "Worker blocked! Check channel capacities!")
    if tasking_done():
      break

proc send_req_worker(ID: int32, req: sink StealRequest) {.inline.} =
  send_req(chan_requests[ID], req)

proc send_req_manager(req: sink StealRequest) {.inline.} =
  send_req(chan_requests[my_partition.manager], req)

proc recv_req(req: var StealRequest): bool =
  profile(send_recv_req):
    result = channel_receive(chan_requests[ID], req.addr, int32 sizeof(req))
    while result and req.state == Failed:
      when defined(DebugTD):
        # Termination detection
        # TODO: add to compile-time options
        log("Worker %d receives STATE_FAILED from worker %d\n", ID, req.ID)
      assert(req.ID == tree.left_child or req.ID == tree.right_child)
      if req.ID == tree.left_child:
        assert not tree.left_subtree_is_idle
        tree.left_subtree_is_idle = true
      else:
        assert not tree.right_subtree_is_idle
        tree.right_subtree_is_idle = true
      # Hold on to this steal request
      enqueue_work_sharing_request(req)
      result = channel_receive(chan_requests[ID], req.addr, int32 sizeof(req))

    # No special treatment for other states
    assert((result and req.state != Failed) or not result)

proc recv_task(task: var Task, idle: bool): bool =
  profile(send_recv_task):
    for i in 0 ..< MaxSteal:
      result = channel_receive(chan_tasks[ID][i], task.addr, int32 sizeof(Task))
      if result:
        channel_push(chan_tasks[ID][i])
        when defined(debug):
          log("Worker %d received a task with function address %d\n", ID, task.fn)
        break

  if not result:
    try_send_steal_request(idle)
  else:
    template tree_waiting_for_tasks(): untyped {.dirty.} =
      assert requested == MaxSteal
      assert channel_stack.top == MaxSteal
      # Adjust value of requested by MaxSteal-1, the number of steal
      # requests that have been dropped:
      # requested = requested - (MaxSteal-1) =
      #           = MaxSteal - MaxSteal + 1 = 1
      requested = 1
      tree.waiting_for_tasks = false
      dropped_steal_requests = 0
    when MaxSteal > 1:
      if tree.waiting_for_tasks:
        tree_waiting_for_tasks()
      else:
        # If we have dropped one or more steal requests before receiving
        # tasks, adjust requested to make sure that we can send MaxSteal
        # steal requests again
        if dropped_steal_requests > 0:
          assert requested > dropped_steal_requests
          requested -= dropped_steal_requests
          dropped_steal_requests = 0
    else:
      if tree.waiting_for_tasks:
        tree_waiting_for_tasks()

    dec requested
    assert requested in 0 ..< MaxSteal
    assert dropped_steal_requests == 0

proc recv_task(task: var Task): bool =
  recv_task(task, true)

proc forget_req(req: sink StealRequest) {.inline.}=
  assert req.ID == ID
  assert requested > 0
  dec requested
  channel_push(req.chan)

var quiescent {.threadvar.}: bool

proc detect_termination() {.inline.} =
  assert ID == MasterID
  assert tree.left_subtree_is_idle and tree.right_subtree_is_idle
  assert not quiescent

  when defined(DebugTD):
    log(">>> Worker %d detects termination <<<\n", ID)
  quiescent = true

# Async actions : Side-effecting pseudo tasks
# -------------------------------------------------------------------

proc async_action(fn: proc (_: pointer) {.nimcall.}, chan: Channel[Task]) =
  ## Asynchronous call of function fn delivered via channel chan
  ## Executed for side effects only

  # Package up and send a dummy task
  profile(send_recv_task):
    let dummy = task_alloc()
    dummy.fn = fn
    dummy.batch = 1
    when defined(StealLastVictim):
      dummy.victim = -1

    let ret = channel_send(chan, dummy, int32 sizeof(Task))
    when defined(debug):
      log("Worker %2d: sending %d async_action\n", ID)
    assert ret

proc notify_workers*(_: pointer) =
  assert not tasking_finished

  if tree.left_child != -1:
    async_action(notify_workers, chan_tasks[tree.left_child][0])
  if tree.right_child != -1:
    async_action(notify_workers, chan_tasks[tree.right_child][0])

  Worker:
    dec num_tasks_exec

  tasking_finished = true

# -------------------------------------------------------------------

const StealAdaptativeInterval{.intdefine.} = 25
  ## Number of steals after which the current strategy is reevaluated
  # TODO: add to compile-time config

var # TODO: solve variable declared in tasking_internal and runtime
  # num_tasks_exec_recently {.threadvar.}: int32
  num_steals_exec_recently {.threadvar.}: int32
  stealhalf {.threadvar.}: bool
  requests_steal_one {.threadvar.}: int32
  requests_steal_half {.threadvar.}: int32

proc try_send_steal_request(idle: bool) =
  ## Try to send a steal request
  ## Every worker can have at most MaxSteal pending steal requests.
  ## A steal request with idle == false indicates that the
  ## requesting worker is still busy working on some tasks.
  ## A steal request with idle == true indicates that
  ## the requesting worker is idle and has nothing to work on

  profile(send_recv_req):
    if requested < MaxSteal:
      when StealStrategy == StealKind.adaptative:
        # Estimate work-stealing efficiency during the last interval
        # If the value is below a threshold, switch strategies
        if num_steals_exec_recently == StealAdaptativeInterval:
          let ratio = num_tasks_exec_recently.float64 / StealAdaptativeInterval.float64
          if stealhalf and ratio < 2:
            stealhalf = false
          elif not stealhalf and ratio == 1:
            stealhalf = true
          num_tasks_exec_recently = 0
          num_steals_exec_recently = 0
      # The following assertion no longer holds because we may increment
      # channel_stack.top without decrementing requested
      # (see dcline_steal_request):
      # assert(requested + channel_stack.top == MaxSteal)
      var req = steal_request_init()
      req.state = if idle: Idle else: Working
      assert req.retry == 0

      when defined(StealLastVictim):
        send_req_worker(steal_from(req, last_victim), req)
      elif defined(StealLastThief):
        send_req_worker(steal_from(req, last_thief), req)
      else:
        send_req_worker(next_victim(req), req)

      inc requested
      inc requests_sent

      when StealStrategy == StealKind.adaptative:
        if stealhalf:
          inc requests_steal_half
        else:
          inc requests_steal_one

proc decline_steal_request(req: var StealRequest) =
  ## Pass steal request on to another worker

  assert req.retry <= MaxStealAttempts
  inc req.retry

  profile(send_recv_req):
    inc requests_declined

    if req.ID == ID:
      # Steal request was returned
      assert req.victims == 0
      if req.state == Idle and tree.left_subtree_is_idle and tree.right_subtree_is_idle:
        template lastStealRequest: untyped {.dirty.} =
          Master:
            detect_termination()
            forget_req(req)
          Worker:
            req.state = Failed
            when defined(DebugTD):
              log("Worker %d sends STATE_FAILED to worker %d\n", ID, tree.parent)
            send_req_worker(tree.parent, req)
            assert not tree.waiting_for_tasks
            tree.waiting_for_tasks = true

        when MaxSteal > 1:
          # Is this the last of MaxSteal Steal Request? If so we can
          # either detect termination, knowing that all workers are idle
          # (ID == MasterID), or we can pass this steal request on to our
          # parent and become quiescent (ID != MasterID). If this is not
          # the last of MaxSteal steal requests, we drop it and wait
          # for the next steal request to be returned.
          if requested == MaxSteal and channel_stack.top == MaxSteal - 1:
            # MaxSteal-1 requests have been dropped as evidenced by
            # the number of channels stashed away in channel_stack.
            assert(dropped_steal_requests == MaxSteal-1)
            lastStealRequest()
          else:
            when defined(DebugTD):
              log("Worker %d drops steal request\n", ID)
            # The master can safely run this assertion as it is never
            # waiting for tasks from its parent (it has none).
            assert not tree.waiting_for_tasks
            # Don't decrement requested to make sure no new steal request
            # is initiated
            channel_push(req.chan)
            inc dropped_steal_requests
        else: # MaxSteal == 1
          lastStealRequest()
      else: # Our request but still working
        # Continue circulating the steal request
        # print_victims(req.victims, ID)
        req.retry = 0
        req.victims = init_victims()
        send_req_worker(next_victim(req), req)
    else: # Not our request
      send_req_worker(next_victim(req), req)

proc decline_all_steal_requests() =
  var req: StealRequest

  profile_stop(Idle)

  if recv_req(req):
    # decline_all_steal_requests is only called when a worker has nothing
    # to do but relay steal requests, which means the worker is idle
    if req.ID == ID and req.state == Working:
      req.state = Idle
    decline_steal_request(req)

  profile_start(Idle)

when defined(LazyFutures):
  # TODO
  proc convert_lazy_futures(task: Task) =
    discard

const StealEarlyThreshold {.intdefine.} = 0
  ## TODO - add to compilation option

proc handle_steal_request(req: var StealRequest) =
  ## Handle a steal request by sending tasks in return
  ## or passing it to another worker

  var task: Task
  var loot = 1'i32

  if req.ID == ID:
    assert req.state != Failed
    task = get_current_task()
    let tasks_left = if not task.isNil and task.is_loop:
                       abs(task.stop - task.cur)
                     else:
                       0
    # Got own steal request
    # Forget about it if we have more tasks than previously
    if deque_list_tl_num_tasks(deque) > StealEarlyThreshold or
                        tasks_left > StealEarlyThreshold:
      forget_req(req)
      return
    else:
      when defined(VictimCheck):
        # Because it's likely that, in the absence of potential victims,
        # we'd end up sending the steal request right back to use, we just
        # give up for now
        forget_req(req)
      else:
        # TODO: Which is more reasonable: continue circulating steal
        #       request or dropping it for now?

        # forget_req(req)
        decline_steal_request(req)
        return

  assert req.ID != ID

  profile(enq_deq_task):
    when StealStrategy == StealKind.adaptative:
      if req.stealhalf:
        task = deque_list_tl_steal_half(deque, loot)
      else:
        task = deque_list_tl_steal(deque)
    elif StealStrategy == StealKind.half:
      task = deque_list_tl_steal_half(deque, loot)
    else: # steal one
      task = deque_list_tl_steal(deque)

  if not task.isNil:
    profile(send_recv_task):
      task.batch = loot
      when defined(StealLastVictim):
        task.victim = ID
      when defined(LazyFutures):
        var t = task
        while not t.isNil:
          if t.has_future:
            convert_lazy_future(t)
          t = t.next
      when defined(debug):
        log("Worker %2d: preparing a task with function address %d\n", ID, task.fn)
      discard channel_send(req.chan, task, int32 sizeof(Task))
        # Cannot block as channels are properly sized.
      when defined(debug):
        log("Worker %2d: sending %d task%s to worker %d\n",
            ID, loot, if loot > 1: "s" else: "", req.ID)
      inc requests_handled
      tasks_sent += loot
      when defined(StealLastThief):
        last_thief = req.ID
  else:
    # There is nothing we can do with this steal request except pass it on
    # to a different worker
    assert deque.deque_list_tl_empty()
    decline_steal_request(req)
    have_no_tasks()

func splittable(t: Task): bool {.inline.} =
  not t.isNil and t.is_loop and abs(t.stop - t.cur) > t.sst

proc handle(req: var StealRequest): bool =
  var this = get_current_task()

  # Send independent task(s) if possible
  if not deque_list_tl_empty(deque):
    handle_steal_request(req)
    return true

  # Split current task if possible
  if splittable(this):
    if req.ID != ID:
      split_loop(this, req)
      return true
    else:
      have_no_tasks()
      forget_req(req)
      return false

  if req.state == Failed:
    # Don't recirculate this steal request
    # TODO: Is this a reasonable decision?
    assert(req.ID == tree.left_child or req.ID == tree.right_child)
  else:
    have_no_tasks()
    decline_steal_request(req)

  return false

proc share_work() =
  # Handle as many work sharing requests as possible.
  # Leave work sharing requests that cannot be answered with tasks enqueued
  while not bounded_queue_empty(work_sharing_requests):
    # Don't dequeue yet
    var req = next_work_sharing_request()
    assert req.ID == tree.left_child or req.ID == tree.right_child
    if handle(req):
      if req.ID == tree.left_child:
        assert tree.left_subtree_is_idle
        tree.left_subtree_is_idle = false
      else:
        assert tree.right_subtree_is_idle
        tree.right_subtree_is_idle = false
      discard dequeue_work_sharing_request()
    else:
      break

proc RT_check_for_steal_requests*() =
  ## Receive and handle steal requests
  # Can be called from user code
  if not bounded_queue_empty(work_sharing_requests):
    share_work()

  if channel_peek(chan_requests[ID]) != 0:
    var req: StealRequest
    while recv_req(req):
      discard handle(req)

proc pop(): Task
proc pop_child(): Task

proc schedule() =
  ## Executed by worker threads

  while true: # Scheduling loop
    # 1. Private task queue
    while (let task = pop(); not task.isNil):
      assert not task.fn.isNil, "Thread: " & $ID & " received a null task function."
      profile(run_task):
        run_task(task)
      profile(enq_deq_task):
        deque_list_tl_task_cache(deque, task)

    # 2. Work-stealing request
    try_send_steal_request(idle = true)
    assert requested != 0

    var task: Task
    profile(idle):
      while not recv_task(task):
        assert deque.deque_list_tl_empty()
        assert requested != 0
        decline_all_steal_requests()

    assert not task.fn.isNil, "Thread: " & $ID & " received a null task function."

    let loot = task.batch
    when defined(StealLastVictim):
      if task.victim != -1:
        last_victim = task.victim
        assert last_victim != ID
    if loot > 1:
      profile(enq_deq_task):
        task = deque_list_tl_pop(deque_list_tl_prepend(deque, task, loot))
        have_tasks()

    when defined(VictimCheck):
      if loot == 1 and splittable(task):
        have_tasks()
    when StealStrategy == StealKind.adaptative:
      inc num_steals_exec_recently

    share_work()

    profile(run_task):
      run_task(task)
    profile(enq_deq_task):
      deque_list_tl_task_cache(deque, task)

    if tasking_done():
      return

proc RT_schedule*() {.inline.}=
  schedule()

type GotoBlocks = enum
  # TODO, remove the need for gotos
  Empty_local_queue
  RT_barrier_exit

proc RT_barrier*() =
  Worker:
    return

  when defined(DebugTD):
    log(">>> Worker %d enters barrier <<<\n", ID)

  assert is_root_task(get_current_task())

  var loc {.goto.} = Empty_local_queue
  case loc
  of Empty_local_queue:
    while (let task = pop(); not task.isNil):
      profile(run_task):
        run_task(task)
      profile(enq_deq_task):
        deque_list_tl_task_cache(deque, task)

    if num_workers == 1:
      quiescent = true
      loc = RT_barrier_exit

    if quiescent:
      loc = RT_barrier_exit

    try_send_steal_request(idle = true)
    assert requested != 0

    var task: Task
    profile(idle):
      while not recv_task(task):
        assert deque.deque_list_tl_empty()
        assert requested != 0
        decline_all_steal_requests()
        if quiescent:
          loc = RT_barrier_exit
            # TODO: the goto will probably breaks profiling

    let loot = task.batch
    when defined(StealLastVictim):
      if task.victim != -1:
        last_victim = task.victim
        assert last_victim != ID

    if loot > 1:
      profile(enq_deq_task):
        task = deque_list_tl_pop(deque_list_tl_prepend(deque, task, loot))
        have_tasks()

    when defined(VictimCheck):
      if loot == 1 and splittable(task):
        have_tasks()

    when StealStrategy == StealKind.adaptative:
      inc num_steals_exec_recently

    share_work()

    profile(run_task):
      run_task(task)
    profile(enq_deq_task):
      deque_list_tl_task_cache(deque, task)
    loc = Empty_local_queue

  of RT_barrier_exit:
    # Execution continues but quiescent remains true until new tasks
    # are created
    assert quiescent

    when defined(DebugTD):
      log(">>> Worker %d leaves barrier <<<\n", ID)

    return

when defined(LazyFutures):
  discard
else:
  type Future = object
    # TODO

  template ready(): untyped = channel_receive(chan, addr(data), size)

  proc RT_force_future*(chan: Channel[Future], data: var Future, size: int32) =
    let this = get_current_task()

    block RT_future_process:
      if ready():
        break RT_future_process

      while (let task = pop_child(); not task.isNil):
        profile(run_task):
          run_task(task)
        profile(enq_deq_task):
          deque_list_tl_task_cache(deque, task)
        if ready():
          break RT_future_process

      assert get_current_task() == this

      while not ready():
        try_send_steal_request(idle = false)
        var task: Task
        profile(idle):
          while not recv_task(task, idle = false):
            # We might inadvertently remove our own steal request in
            # handle_steal_request, so:
            profile_stop(idle)
            try_send_steal_request(idle = false)
            # Check if someone requested to steal from us
            var req: StealRequest
            while recv_req(req):
              handle_steal_request(req)
            profile_start(idle)
            if ready():
              profile_stop(idle)
              break RT_future_process

        let loot = task.batch
        when defined(StealLastVictim):
          if task.victim != -1:
            last_victim = task.victim
            assert last_victim != ID

        if loot > 1:
          profile(enq_deq_task):
            task = deque_list_tl_pop(deque_list_tl_prepend(deque, task, loot))
            have_tasks()

        when defined(VictimCheck):
          if loot == 1 and splittable(task):
            have_tasks()

        when StealStrategy == StealKind.adaptative:
          inc num_steals_exec_recently

        share_work()

        profile(run_task):
          run_task(task)
        profile(enq_deq_task):
          deque_list_tl_task_cache(deque, task)

      # End block RT_future_process
    block RT_force_future_return:
      when defined(LazyFutures):
        # TODO
        discard
      else:
        return

# Tasks helpers
# -------------------------------------------------------------------

proc push*(task: sink Task) =
  assert not task.fn.isNil, "Thread: " & $ID & " pushed a null task function."
  deque.deque_list_tl_push(task)
  have_tasks()

  profile_stop(enq_deq_task)

  # Master
  if quiescent:
    assert ID == MasterID
    when defined(DebugTD):
      log(">>> Worker %d resumes execution after barrier <<<\n", ID)
    quiescent = false

  share_work()

  # Check if someone requested to steal from us
  var req: StealRequest
  while recv_req(req):
    handle_steal_request(req)

  profile_start(enq_deq_task)

when StealEarlyThreshold > 0:
  proc try_steal() =
    # Try to send a steal request when number of local tasks <= StealEarlyThreashold
    if num_workers ==1:
      return

    if deque_list_tl_num_tasks(deque) <= StealEarlyThreshold:
      # By definition not yet idle
      try_send_steal_request(idle = false)

proc popImpl(task: Task) =

  # Sending an idle steal request at this point may lead
  # to termination detection when we're about to quit!
  # Steal requests with idle == false are okay.
  when StealEarlyThreshold > 0:
    if not task.isNil and not task.is_loop:
      try_steal()

  share_work()

  # Check if someone requested to steal from us
  var req: StealRequest
  while recv_req(req):
    # If we just popped a loop task, we may split right here
    # Makes handle_steal_request simpler
    if deque_list_tl_empty(deque) and splittable(task):
      if req.ID != ID:
        split_loop(task, req)
      else:
        forget_req(req)
    else:
      handle_steal_request(req)

proc pop(): Task =
  profile(enq_deq_task):
    result = deque_list_tl_pop(deque)

  when defined(VictimCheck):
    if result.isNil:
      have_no_tasks()

  popImpl(result)

proc pop_child(): Task =
  profile(enq_deq_task):
    result = deque_list_tl_pop_child(deque, get_current_task())

  popImpl(result)

# Split loops
# -------------------------------------------------------------------

func split_half(task: Task): int {.inline.} =
  # Split iteration range in half
  task.cur + (task.stop - task.cur) div 2

func split_guided(task: Task): int {.inline.} =
  # Split iteration range based on the number of workers
  assert task.chunks > 0
  let iters_left = abs(task.stop - task.cur)
  assert iters_left > task.sst

  if iters_left <= task.chunks:
    return split_half(task)

  # LOG("Worker %2d: sending %ld iterations\n", ID, task.chunks)
  return task.stop - task.chunks

template idle_workers: untyped {.dirty.} =
  channel_peek(chan_requests[ID])

proc split_adaptative(task: Task): int {.inline.} =
  ## Split iteration range based on the number of steal requests
  let iters_left = abs(task.stop - task.cur)
  assert iters_left > task.sst

  # log("Worker %2d: %ld of %ld iterations left\n", ID, iters_left, iters_total)

  # We have already received one steal request
  let num_idle = idle_workers + 1

  # log("Worker %2d: have %ld steal requests\n", ID, num_idle)

  # Every thief receives a chunk
  let chunk = max(iters_left div (num_idle + 1), 1)

  assert iters_left > chunk

  # log("Worker %2d: sending %ld iterations\n", ID, chunk)
  return task.stop - chunk

func split_func(task: Task): int {.inline.} =
  when SplitStrategy == SplitKind.half:
    split_half(task)
  elif SplitStrategy == guided:
    split_guided(task)
  else:
    split_adaptative(task)

proc split_loop(task: Task, req: sink StealRequest) =
  assert req.ID == ID

  profile(enq_deq_task):
    let dup = task_alloc()

    # Copy of the current task
    dup[] = task[]

    # Split iteration range according to given strategy
    # [start, stop[ => [start, split[ + [split, end[
    # TODO: Nim inclusive intervals?
    let split = split_func(task)

    # New task gets upper half of iterations
    dup.start = split
    dup.cur = split
    dup.stop = task.stop

  log("Worker %2d: Sending [%ld, %ld) to worker %d\n", ID, dup.start, dup.stop, req.ID);

  profile(send_recv_task):
    dup.batch = 1
    when defined(StealLastVictim):
      dup.victim = ID

    if dup.has_future:
      # TODO
      discard

    discard channel_send(req.chan, dup, int32 sizeof(dup))
    inc requests_handled
    inc tasks_sent
    when defined(StealLastThief):
      last_thief = req.ID

    # Current task continues with lower half of iterations
    task.stop = split

    inc tasks_split

  # log("Worker %2d: Continuing with [%ld, %ld)\n", ID, task->cur, task->end)
