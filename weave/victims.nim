# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[sync_types, context_thread_local, bounded_queues,
               prell_deques, flowvars, binary_worker_trees],
  ./contexts, ./config,
  ./instrumentation/[contracts, profilers, loggers],
  ./cross_thread_com/[channels_spsc_single_ptr, channels_mpsc_unbounded_batch, channels_spsc_single, scoped_barriers],
  ./thieves, ./loop_splitting,
  ./state_machines/decline_thief

{.push gcsafe.}

# Victims - Proxy handling on behalf of idle child workers
# ----------------------------------------------------------------------------------

proc hasThievesProxy*(worker: WorkerID): bool =
  ## Check if a worker has steal requests pending
  ## This also checks the child of this worker
  if worker == Not_a_worker:
    return false

  for w in traverseBreadthFirst(worker, maxID()):
    if getThievesOf(w).peek() > 0:
      return true
  return false

Backoff:
  proc recvProxy(req: var StealRequest, worker: WorkerID): bool =
    ## Receives steal requests on behalf of child workers
    ## Note that on task reception, children are waken up
    ## and tasks are sent to them before thieves so this should happen rarely
    if worker == Not_a_worker:
      return false

    profile(send_recv_req):
      for w in traverseBreadthFirst(worker, maxID()):
        result = getThievesOf(w).tryRecv(req)
        if result:
          return true
    return false

# Victims - Adaptative task splitting
# ----------------------------------------------------------------------------------

Backoff:
  proc approxNumThievesProxy(worker: WorkerID): int32 =
    # Estimate the number of idle workers of a worker subtree
    if worker == Not_a_worker:
      return 1 # The child worker is also idling
    result = 0
    var count = 0'i32
    for w in traverseBreadthFirst(worker, maxID()):
      result += getThievesOf(w).peek()
      count += 1
    debug: log("Worker %2d: found %ld steal requests addressed to its child %d and grandchildren (%d workers) \n", myID(), result, worker, count)
    # When approximating the number of thieves we need to take the
    # work-sharing requests into account, i.e. 1 task per child
    result += count

# Victims - Steal requests handling
# ----------------------------------------------------------------------------------

proc recv*(req: var StealRequest): bool {.inline.} =
  ## Check the worker theft channel
  ## for thieves.
  ##
  ## Updates req and returns true if a StealRequest was found

  profile(send_recv_req):
    result = myThieves().tryRecv(req)

    # debug:
    #   if result:
    #     log("Worker %2d: receives request 0x%.08x from %d with %d potential victims. (Channel: 0x%.08x)\n",
    #           myID(), cast[ByteAddress](req), req.thiefID, req.victims.len, myThieves().addr)

    # We treat specially the case where children fail to steal
    # and defer to the current worker (their parent)
    while result and req.state == Waiting:
      debugTermination:
        log("Worker %2d: receives state passively WAITING from its child worker %d (left (%d): %s, right (%d): %s)\n",
            myID(), req.thiefID,
            myWorker().left,
            if myWorker().leftIsWaiting: "waiting" else: "not waiting",
            myWorker().right,
            if myWorker().rightIsWaiting: "waiting" else: "not waiting"
          )

      # Only children can forward a request where they sleep
      ascertain: req.thiefID == myWorker().left or
                 req.thiefID == myWorker().right
      if req.thiefID == myWorker().left:
        ascertain: not myWorker().leftIsWaiting
        myWorker().leftIsWaiting = true
      else:
        ascertain: not myWorker().rightIsWaiting
        myWorker().rightIsWaiting = true
      # The child is now passive (work-sharing/sender-initiated/push)
      # instead of actively stealing (receiver-initiated/pull)
      # We keep its steal request for when we have more work.
      # while it backs off to save CPU
      myWorker().workSharingRequests.enqueue(req)
      # Check the next steal request
      result = myThieves().tryRecv(req)

    Backoff:
      # When a child thread backs off, it is parked by the OS
      # We need to handle steal requests on its behalf to avoid latency
      if not result and myWorker().leftIsWaiting:
        result = recvProxy(req, myWorker().left)

      if not result and myWorker().rightIsWaiting:
        result = recvProxy(req, myWorker().right)

  postCondition: not result or (result and req.state != Waiting)

template receivedOwn(req: sink StealRequest) =
  preCondition: req.state != Waiting

  when WV_StealEarly > 0:
    let task = myTask()
    let tasksLeft = if not task.isNil and task.isLoop:
                      ascertain: task.stop > task.cur
                      (task.stop - task.cur + task.stride-1) div task.stride
                    else: 0

    # Received our own steal request, we can forget about it
    # if we now have more tasks that the threshold
    if myWorker().deque.pendingTasks > WV_StealEarly or
        tasksLeft > WV_StealEarly:
      req.forget()
    else:
      decline(req)
  else:
    decline(req)

proc takeTasks(req: StealRequest): tuple[task: Task, loot: int32] =
  ## Take tasks in the worker deque to send them
  ## to others

  if req.state == Waiting:
    # Always steal-half for child thread to
    # try to wakeup the whole tree.
    myWorker().deque.stealHalf(result.task, result.loot)
    return

  when StealStrategy == StealKind.adaptative:
    if req.stealHalf:
      myWorker().deque.stealHalf(result.task, result.loot)
    else:
      result.task = myWorker().deque.steal()
      result.loot = 1
  elif StealStrategy == StealKind.half:
    myWorker().deque.stealHalf(result.task, result.loot)
  else:
    result.task = myWorker().deque.steal()
    result.loot = 1

proc send(req: sink StealRequest, task: sink Task, numStolen: int32 = 1) {.inline.}=
  debug: log("Worker %2d: sending %d tasks (task.fn 0x%.08x) to Worker %2d\n",
    myID(), numStolen, task.fn, req.thiefID, req.thiefAddr)
  let taskSent {.used.} = req.thiefAddr[].trySend(task)
  TargetLastThief:
    myThefts().lastThief = req.thiefID

  postCondition: taskSent # SPSC channel with only 1 slot

  incCounter(stealHandled)
  incCounter(tasksSent, numStolen)

proc dispatchElseDecline*(req: sink StealRequest) =
  ## Send tasks in return of a steal request
  ## or decline and relay the steal request to another thread

  if req.thiefID == myID():
    receivedOwn(req)
    return

  profile(enq_deq_task):
    let (task, loot) = req.takeTasks()

  if not task.isNil:
    ascertain: not task.fn.isNil
    ascertain: cast[ByteAddress](task.fn) != 0xFACADE
    profile(send_recv_task):
      TargetLastVictim:
        task.victim = myID()
      LazyFV:
        batchConvertLazyFlowvar(task)
      debug: log("Worker %2d: preparing %d task(s) for worker %2d with function address 0x%.08x\n",
        myID(), loot, req.thiefID, task.fn)
      req.send(task, loot)
  else:
    ascertain: myWorker().deque.isEmpty()
    decline(req)

proc evalSplit(task: Task, req: StealRequest, workSharing: bool): int =
  when SplitStrategy == SplitKind.half:
    return splitHalf(task)
  elif SplitStrategy == guided:
    return splitGuided(task)
  elif SplitStrategy == SplitKind.adaptative:
    var guessThieves = myThieves().peek()
    debugSplit: log("Worker %2d: has %ld steal requests queued\n", myID(), guessThieves)
    Backoff:
      if workSharing:
        # The real splitting will be done by the child worker
        # We need to send it enough work for its own children and all the steal requests pending
        ascertain: req.thiefID == myWorker().left or req.thiefID == myWorker().right
        var left, right = 0'i32
        if myWorker().leftIsWaiting:
          left = approxNumThievesProxy(myWorker().left)
        if myWorker().rightIsWaiting:
          right = approxNumThievesProxy(myWorker().right)
        guessThieves += left + right
        debugSplit:
          log("Worker %2d: workSharing split, thiefID %d, total subtree thieves %d, left{id: %d, waiting: %d, requests: %d}, right{id: %d, waiting: %d, requests: %d}\n",
            myID(), req.thiefID, guessThieves, myWorker().left, myWorker().leftIsWaiting, left, myWorker().right, myWorker().rightIsWaiting, right
          )
        if req.thiefID == myWorker().left:
          return splitAdaptativeDelegated(task, guessThieves, left)
        else:
          return splitAdaptativeDelegated(task, guessThieves, right)
      # ------------------------------------------------------------
      if myWorker().leftIsWaiting:
        guessThieves += approxNumThievesProxy(myWorker().left)
      if myWorker().rightIsWaiting:
        guessThieves += approxNumThievesProxy(myWorker().right)
    # If not "workSharing" we also just dequeued the steal request currently being considered
    # so we need to add it back
    return splitAdaptative(task, 1+guessThieves)
  else:
    {.error: "Unreachable".}

proc splitAndSend*(task: Task, req: sink StealRequest, workSharing: bool) =
  ## Split a task and send a part to the thief
  preCondition: req.thiefID != myID()

  profile(enq_deq_task):
    let upperSplit = newTaskFromCache()

    # Copy the current task
    upperSplit[] = task[]
    TargetLastVictim:
      upperSplit.victim = myID()

    # Increment the number of tasks the scoped barrier (if any) has to wait for
    upperSplit.scopedBarrier.registerDescendant()

    # Split iteration range according to given strategy
    # [start, stop) => [start, split) + [split, end)
    let split = evalSplit(task, req, workSharing)

    # New task gets the upper half
    upperSplit.start = split
    upperSplit.cur = split
    upperSplit.stop = task.stop
    upperSplit.isInitialIter = false

    # Current task continues with lower half
    task.stop = split

  ascertain: upperSplit.stop > upperSplit.start
  ascertain: task.stop > task.cur

  profile(send_recv_task):
    if upperSplit.hasFuture:
      # The task has a future so it depends on both splitted tasks.
      let fvNode = newFlowvarNode(upperSplit.futureSize)
      # Redirect the result channel of the upperSplit
      LazyFv:
        cast[ptr ptr LazyFlowVar](upperSplit.data.addr)[] = fvNode.lfv
      EagerFv:
        cast[ptr ptr ChannelSPSCSingle](upperSplit.data.addr)[] = fvNode.chan
      fvNode.next = cast[FlowvarNode](task.futures)
      task.futures = cast[pointer](fvNode)
      # Don't share the required futures with the child
      upperSplit.futures = nil

    debugSplit:
      let steps = (upperSplit.stop-upperSplit.start + upperSplit.stride-1) div upperSplit.stride
      log("Worker %2d: Sending [%ld, %ld) to worker %d (%d steps) (hasFuture: %d, dependsOnFutures: 0x%.08x)\n", myID(), upperSplit.start, upperSplit.stop, req.thiefID, steps, upperSplit.hasFuture, upperSplit.futures)

    req.send(upperSplit)

  incCounter(loopsSplit)
  debug:
    let steps = (task.stop-task.cur + task.stride-1) div task.stride
    log("Worker %2d: Continuing with [%ld, %ld) (%d steps) (hasFuture: %d, dependsOnFutures: 0x%.08x)\n", myID(), task.cur, task.stop, steps, task.hasFuture, task.futures)

proc distributeWork*(req: sink StealRequest, workSharing: bool): bool =
  ## Distribute work during load balancing or work-sharing requests
  ## Returns true if we found work
  ## false otherwise

  # Send independent task(s) if possible
  if not myWorker().deque.isEmpty():
    req.dispatchElseDecline()
    return true
    # TODO - the control flow is entangled here
    #        since we have a non-empty deque we will never take
    #        the branch that leads to termination
    #        and would logically return true

  Manager:
    # Drain all the jobs otherwise
    var firstJob, lastJob: Job
    let count = managerJobQueue.tryRecvBatch(firstJob, lastJob)
    if count != 0:
      # TODO: https://github.com/mratsim/weave/issues/155
      # myWorker().deque.addListFirst(
      #   cast[Task](firstJob),
      #   cast[Task](lastJob),
      #   count
      # )
      myWorker().deque.addListFirst(cast[Task](lastJob))
      req.dispatchElseDecline()
      return true

  # Otherwise try to split the current task
  if myTask().isSplittable():
    if req.thiefID != myID():
      myTask().splitAndSend(req, workSharing)
      return true
    else:
      req.forget()
      return false

  if req.state == Waiting:
    # Only children can send us a failed state.
    # Request should be saved by caller and
    # worker tree updates should be done by caller as well
    # TODO: disantangle control-flow and sink the request
    postCondition: req.thiefID == myWorker().left or req.thiefID == myWorker().right
  else:
    decline(req)

  return false

proc shareWork*() {.inline.} =
  ## Distribute work to all the idle children workers
  ## if we can
  while not myWorker().workSharingRequests.isEmpty():
    # Only dequeue if we find work
    let req = myWorker().workSharingRequests.peek()
    ascertain: req.thiefID == myWorker().left or req.thiefID == myWorker.right
    if distributeWork(req, workSharing = true): # Shouldn't this need a copy?
      if req.thiefID == myWorker().left:
        ascertain: myWorker().leftIsWaiting
        myWorker().leftIsWaiting = false
      else:
        ascertain: myWorker().rightIsWaiting
        myWorker().rightIsWaiting = false
      Backoff:
        wakeup(req.thiefID)

      # Now we can dequeue as we found work
      # We cannot access the steal request anymore or
      # we would have a race with the child worker recycling it.
      discard myWorker().workSharingRequests.dequeue()
    else:
      break
