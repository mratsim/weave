# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[sync_types, context_thread_local, bounded_queues,
               sparsesets, prell_deques, flowvars],
  ./contexts, ./config,
  ./instrumentation/[contracts, profilers, loggers],
  ./channels/[channels_spsc_single_ptr, channels_mpsc_unbounded_batch, channels_lazy_flowvars],
  ./thieves, ./loop_splitting,
  ./memory/memory_pools

# Victims - Adaptative task splitting
# ----------------------------------------------------------------------------------

proc approxNumThieves(): int32 {.inline.} =
  # We estimate the number of idle workers by counting the number of theft attempts
  # Notes:
  #   - We peek into a MPSC channel from the consumer thread: the peek is a lower bound
  #     as more requests may pile up concurrently.
  #   - We already read 1 steal request before trying to split so need to add it back.
  #   - Workers may send steal requests before actually running out-of-work
  let approxNumThieves = 1 + myThieves().peek()
  debug: log("Worker %2d: has %ld steal requests\n", myID(), approxNumThieves)

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
        log("Worker %2d: receives state passively WAITING from its child worker %d\n",
            myID(), req.thiefID)

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

  postCondition: not result or (result and req.state != Waiting)

proc declineOwn(req: sink StealRequest) =
  ## Decline our own steal request
  # No one had jobs to steal
  preCondition: req.victims.isEmpty()

  debugTermination:
    log("Worker %2d: received own request (req.state: %s, left: %d, right %d)\n", myID(), $req.state, myWorker().leftIsWaiting, myWorker().rightIsWaiting)

  if req.state == Stealing and myWorker().leftIsWaiting and myWorker().rightIsWaiting:
    when WV_MaxConcurrentStealPerWorker == 1:
      # When there is only one concurrent steal request allowed, it's always the last.
      lastStealAttempt(req)
    else:
      # Is this the last theft attempt allowed per steal request?
      # - if so: lastStealAttempt special case (termination if lead thread, sleep if worker)
      # - if not: drop it and wait until we receive work or all out steal requests failed.
      if myThefts().outstanding == WV_MaxConcurrentStealPerWorker and
          myTodoBoxes().len == WV_MaxConcurrentStealPerWorker - 1:
        # "WV_MaxConcurrentStealPerWorker - 1" steal requests have been dropped
        # as evidenced by the corresponding channel "address boxes" being recycled
        ascertain: myThefts().dropped == WV_MaxConcurrentStealPerWorker - 1
        lastStealAttempt(req)
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

proc receivedOwn(req: sink StealRequest) =
  preCondition: req.state != Waiting

  when WV_StealEarly > 0:
    task = myTask()
    let tasksLeft = if not task.isNil and task.isLoop:
                      abs(task.stop - task.cur)
                    else: 0

    # Received our own steal request, we can forget about it
    # if we now have more tasks that the threshold
    if myWorker().deque > WV_StealEarly or
        tasksLeft > WV_StealEarly:
      req.forget()
  else:
    decline(req)

proc takeTasks(req: StealRequest): tuple[task: Task, loot: int32] =
  ## Take tasks in the worker deque to send them
  ## to other
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
  when defined(WV_LastThief):
    myThefts().lastThief = req.thiefID

  postCondition: taskSent # SPSC channel with only 1 slot

  incCounter(stealHandled)
  incCounter(tasksSent, numStolen)

LazyFV:
  proc convertLazyFlowvar(task: Task) {.inline.} =
    # Allocate the Lazy future on the heap to extend its lifetime
    var lfv: LazyFlowvar
    copyMem(lfv.addr, task.data.addr, sizeof(LazyFlowvar))
    if not lfv.hasChannel:
      lfv.hasChannel = true
      # TODO, support bigger than pointer size
      lfv.lazy.chan = newChannelLazyFlowvar(myMemPool(), itemsize = sizeof(LazyChannel))
      incCounter(futuresConverted)

  proc batchConvertLazyFlowvar(task: Task) =
    var task = task
    while not task.isNil:
      if task.hasFuture:
        convertLazyFlowvar(task)
      task = task.next

proc dispatchTasks*(req: sink StealRequest) =
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
    let split = split(task, approxNumThieves())

    # New task gets the upper half
    dup.start = split
    dup.cur = split
    dup.stop = task.stop

  log("Worker %2d: Sending [%ld, %ld) to worker %d\n", myID(), dup.start, dup.stop, req.thiefID)

  profile(send_recv_task):
    dup.batch = 1
    # TODO StealLastVictim

    if dup.hasFuture:
      # TODO
      discard

    req.send(dup)

    # Current task continues with lower half
    myTask().stop = split

  incCounter(tasksSplit)

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
      # Now we can dequeue as we found work
      discard myWorker().workSharingRequests.dequeue()
    else:
      break
