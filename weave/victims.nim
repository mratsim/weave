# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[sync_types, context_thread_local, bounded_queues,
               sparsesets, prell_deques, flowvars, binary_worker_trees],
  ./contexts, ./config,
  ./instrumentation/[contracts, profilers, loggers],
  ./channels/[channels_spsc_single_ptr, channels_mpsc_unbounded_batch, channels_spsc_single],
  ./thieves, ./loop_splitting,
  ./memory/memory_pools

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

proc approxNumThieves(): int32 {.inline.} =
  # We estimate the number of idle workers by counting the number of theft attempts
  # Notes:
  #   - We peek into a MPSC channel from the consumer thread: the peek is a lower bound
  #     as more requests may pile up concurrently.
  #   - We already read 1 steal request before trying to split so need to add it back.
  #   - Workers may send steal requests before actually running out-of-work
  result = 1 + myThieves().peek()
  debug: log("Worker %2d: has %ld steal requests\n", myID(), approxNumThieves)

proc approxNumThievesProxy(worker: WorkerID): int32 =
  # Estimate the number of idle workers of a worker subtree
  result = 0
  for w in traverseBreadthFirst(worker, maxID()):
    result += getThievesOf(w).peek()
  debug: log("Worker %2d: found %ld steal requests addressed to its child %d and grandchildren\n", myID(), result, worker)

# Victims - Steal requests handling
# ----------------------------------------------------------------------------------

proc recv*(req: var StealRequest): bool {.inline.} =
  ## Check the worker theft channel
  ## for thieves.
  ##
  ## Updates req and returns true if a StealRequest was found

  profile(send_recv_req):
    result = myThieves().tryRecv(req)

    debug:
      if result:
        log("Worker %2d: receives request 0x%.08x from %d with %d potential victims. (Channel: 0x%.08x)\n",
              myID(), cast[ByteAddress](req), req.thiefID, req.victims.len, myThieves().addr)

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

    # # When a child thread backs off, it is parked by the OS
    # # We need to handle steal requests on its behalf to avoid latency
    # if not result and myWorker().leftIsWaiting:
    #   result = recvProxy(req, myWorker().left)

    # if not result and myWorker().rightIsWaiting:
    #   result = recvProxy(req, myWorker().right)

  postCondition: not result or (result and req.state != Waiting)

proc declineOwn(req: sink StealRequest) =
  ## Decline our own steal request

  # The assumption that no one had jobs to steal
  # does not hold when we process our child requests
  # we might have taken one we sent to our children
  # TODO: how to prevent cascading sleep
  # preCondition: req.victims.isEmpty()

  debug:
    log("Worker %2d: received own request (req.state: %s, left (%d): %s, right (%d): %s)\n",
      myID(), $req.state,
      myWorker().left,
      if myWorker().leftIsWaiting: "waiting" else: "not waiting",
      myWorker().right,
      if myWorker().rightIsWaiting: "waiting" else: "not waiting")

  if req.state == Stealing and myWorker().leftIsWaiting and myWorker().rightIsWaiting:
    when WV_MaxConcurrentStealPerWorker == 1:
      # When there is only one concurrent steal request allowed, it's always the last.
      lastStealAttemptFailure(req)
    else:
      # Is this the last theft attempt allowed per steal request?
      # - if so: lastStealAttemptFailure special case (termination if lead thread, sleep if worker)
      # - if not: drop it and wait until we receive work or all out steal requests failed.
      if myThefts().outstanding == WV_MaxConcurrentStealPerWorker and
          myTodoBoxes().len == WV_MaxConcurrentStealPerWorker - 1:
        # "WV_MaxConcurrentStealPerWorker - 1" steal requests have been dropped
        # as evidenced by the corresponding channel "address boxes" being recycled
        ascertain: myThefts().dropped == WV_MaxConcurrentStealPerWorker - 1
        lastStealAttemptFailure(req)
      else:
        drop(req)
  else:
    # Our own request but we still have work, so we reset it and recirculate.
    ascertain: req.victims.capacity.int32 == workforce()
    req.retry = 0
    req.victims.refill()
    req.victims.excl(myID())
    req.findVictimAndRelaySteal()

proc decline*(req: sink StealRequest) =
  ## Pass steal request to another worker
  ## or the manager if it's our own that came back
  preCondition: req.retry <= WV_MaxRetriesPerSteal

  req.retry += 1
  incCounter(stealDeclined)

  profile(send_recv_req):
    if req.thiefID == myID():
      req.declineOwn()
    else: # Not our own request
      req.victims.excl(myID())
      req.findVictimAndRelaySteal()

template receivedOwn(req: sink StealRequest) =
  preCondition: req.state != Waiting

  when WV_StealEarly > 0:
    let task = myTask()
    let tasksLeft = if not task.isNil and task.isLoop:
                      ascertain: task.stop > task.cur
                      (task.stop - task.cur) div task.stride
                    else: 0

    # Received our own steal request, we can forget about it
    # if we now have more tasks that the threshold
    if myWorker().deque.pendingTasks > WV_StealEarly or
        tasksLeft > WV_StealEarly:
      req.forget()
  else:
    decline(req)

proc takeTasks(req: StealRequest): tuple[task: Task, loot: int32] =
  ## Take tasks in the worker deque to send them
  ## to others
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
  let taskSent = req.thiefAddr[].trySend(task)

  postCondition: taskSent # SPSC channel with only 1 slot

  incCounter(stealHandled)
  incCounter(tasksSent, numStolen)

proc dispatchTasks*(req: sink StealRequest) {.gcsafe.}=
  ## Send tasks in return of a steal request
  ## or decline and relay the steal request to another thread

  if req.thiefID == myID():
    receivedOwn(req)
    return

  profile(enq_deq_task):
    let (task, loot) = req.takeTasks()

  if not task.isNil:
    profile(send_recv_task):
      task.batch = loot
      # TODO LastVictim
      LazyFV:
        batchConvertLazyFlowvar(task)
      debug: log("Worker %2d: preparing %d task(s) for worker %2d with function address 0x%.08x\n",
        myID(), loot, req.thiefID, task.fn)
      req.send(task, loot)
  else:
    ascertain: myWorker().deque.isEmpty()
    decline(req)

proc splitAndSend*(task: Task, req: sink StealRequest) =
  ## Split a task and send a part to the thief
  preCondition: req.thiefID != myID()

  profile(enq_deq_task):
    let dup = newTaskFromCache()

    # Copy the current task
    dup[] = task[]

    # Split iteration range according to given strategy
    # [start, stop) => [start, split) + [split, end)
    var guessThieves = approxNumThieves()
    # if myWorker().leftIsWaiting:
    #   guessThieves += approxNumThievesProxy(myWorker().left)
    # if myWorker().rightIsWaiting:
    #   guessThieves += approxNumThievesProxy(myWorker().right)
    let split = split(task, guessThieves)

    # New task gets the upper half
    dup.start = split
    dup.cur = split
    dup.stop = task.stop

    # Current task continues with lower half
    task.stop = split

  debug: log("Worker %2d: Sending [%ld, %ld) to worker %d\n", myID(), dup.start, dup.stop, req.thiefID)

  profile(send_recv_task):
    dup.batch = 1

    if dup.hasFuture:
      # The task has a future so it depends on both splitted tasks.
      #
      # Problem: we lost the type information so we don't
      # know the size. The type erased channel supports up to WV_MemBlockSize - 11 bytes
      # This also prevents us from using the typed SPSC channels
      let fvNode = newFlowvarNode(dup.futureSize)
      # Redirect the result channel of the dup
      LazyFv:
        copyMem(dup.data.addr, fvNode.lfv.lazy.chan.addr, sizeof(pointer))
      EagerFv:
        copyMem(dup.data.addr, fvNode.chan.addr, sizeof(pointer))
      fvNode.next = cast[FlowvarNode](myTask().futures)
      myTask().futures = cast[pointer](fvNode)
      # Don't share the required futures with the child
      dup.futures = nil

    req.send(dup)

  incCounter(tasksSplit)
  debug: log("Worker %2d: Continuing with [%ld, %ld)\n", myID(), task.cur, task.stop)

proc distributeWork(req: sink StealRequest): bool =
  ## Handle incoming steal request
  ## Returns true if we found work
  ## false otherwise

  # Send independent task(s) if possible
  if not myWorker().deque.isEmpty():
    req.dispatchTasks()
    return true
    # TODO - the control flow is entangled here
    #        since we have a non-empty deque we will never take
    #        the branch that leads to termination
    #        and would logically return true

  # Otherwise try to split the current one
  if myTask().isSplittable():
    if req.thiefID != myID():
      myTask().splitAndSend(req)
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
    if distributeWork(req): # Shouldn't this need a copy?
      if req.thiefID == myWorker().left:
        ascertain: myWorker().leftIsWaiting
        myWorker().leftIsWaiting = false
      else:
        ascertain: myWorker().rightIsWaiting
        myWorker().rightIsWaiting = false
      # wakeup(req.thiefID) - backoff is deactivated

      # Now we can dequeue as we found work
      # We cannot access the steal request anymore or
      # we would have a race with the child worker recycling it.
      discard myWorker().workSharingRequests.dequeue()
    else:
      break
