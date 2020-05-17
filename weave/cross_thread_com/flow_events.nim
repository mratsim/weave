# Weave
# Copyright (c) 2020 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # stdlib
  std/[atomics, macros],
  # Internals
  ./channels_mpsc_unbounded_batch,
  ../datatypes/sync_types,
  ../memory/[allocs, memory_pools],
  ../instrumentation/[contracts, loggers],
  ../config

# Flow Events
# ----------------------------------------------------
# FlowEvents are the counterpart to Flowvars.
#
# When a task depends on an event, it is delayed until the event is triggered
# This allows to model precise dependencies between tasks
# beyond what traditional control-flow dependencies (function calls, barriers, locks) allow.
#
# Furthermore control-flow dependencies like barriers and locks suffer from:
# - composability problem (barriers are incompatible with work stealing or nested parallelism).
# - restrict the parallelism exposed.
# - expose the programmers to concurrency woes that could be avoided
#   by specifying precede/after relationship
#
# This data-availability-based parallelism is also called:
# - dataflow parallelism
# - graph parallelism
# - data-driven task parallelism
# - pipeline parallelism
# - stream parallelism
#
#
# Details, use-cases, competing approaches provided at: https://github.com/mratsim/weave/issues/31
#
# Protocol (https://github.com/mratsim/weave/pull/92#issuecomment-570795718)
# ----------------------------------------------------
#
# A flow event is an ownerless MPSC channel that holds tasks.
# The number of tasks in the channel is bounded by the number of dependent tasks
# When a worker triggers an event, it becomes the unique consumer of the MPSC channel.
# It flags the event as triggered and drain the channel of all tasks.
# When a task is dependent on an event, the worker that received the dependent task
# checks the triggered flag.
# Case 1: It is already triggered, it schedules the task as a normal task
# Case 2: It is not triggered, it sends the task in the flow event MPSC channel.
#
# Tasks with multiple dependencies are represented by a linked list of events
# When a task is enqueued, it is sent to one of the untriggered event channels at random
# When that event is triggered, if all other events were also triggered, it can be scheduled immediately
# Otherwise it is sent to one of the untriggered events at random.
#
# Memory management is done through atomic reference counting.
# Events for loop iterations can use a single reference count for all iterations,
# however each iteration should have its event channel. This has a memory cost,
# users should be encouraged to use loop tiling/blocking.
#
# Mutual exclusion
# There is a race if a producer worker triggers an event and a consumer
# checks the event status.
# In our case, the triggered flag is write-once, the producer worker only requires
# a way to know if a data race could have occurred.
#
# The event keeps 2 monotonically increasing atomic count of consumers in and consumers out
# When a consumer checks the event:
# - it increments the consumer count "in"
# - on exit it always increments the consumer count "out"
# - if it's triggered, increments the consumer count "out",
#   then exits and schedule the task itself
# - if it's not, it enqueues the task
#   Then increments the count out
# - The producer thread checks after draining all tasks that the consumer in/out counts are the same
#   otherwise it needs to drain again until it is sure that the consumer is out.
# Keeping 2 count avoids the ABA problem.
# Events are allocated from memory pool blocks of size 2x WV_CacheLinePadding (256 bytes)
# with an intrusive MPSC channel
#
# Analysis:
# This protocol avoids latency between when the data is ready and when the task is scheduled
# exposing the maximum amount of parallelism.
# Proof: As soon as the event is triggered, any dependent tasks are scheduled
#        or the task was not yet created. Tasks created late are scheduled immediately by the creating worker.
#
# This protocol minimizes the number of messages sent. There is at most 1 per dependency unlike
# a gossipsub, floodsub or episub approach which sends an exponential number of messages
# and are sensitive to relayers' delays.
#
# This protocol avoids any polling. An alternative approach would be to have
# worker that creates the dependent tasks to keep it in their queue
# and then subscribe to a dependency readiness channel (pubsub).
# They would need to regularly poll, which creates latency (they also have work)
# and also might require them to scan possibly long sequences of dependencies.
#
# This protocol avoids the need of multiple hash-tables or a graph-library
# to map FlowEvent=>seq[Task] and Task=>seq[FlowEvent] to quickly obtain
# all tasks that can be scheduled from a triggered event and
# to track the multiple event dependencies a task can have.
#
# In particular this play well with the custom memory pool of Weave, unlike Nim sequences or hash-tables.
#
# This protocol is cache friendly. The deferred task is co-located with the producer event.
# When scheduled, it will use data hot in cache unless task is stolen but it can only be stolen if it's the
# only task left due to LIFO work and FIFO thefts.
#
# This protocol doesn't impose ordering on the producer and consumer (event triggerer and event dependent task).
# Other approaches might lead to missed messages unless they introduce state/memory,
# which is always complex in "distributed" long-lived computations due to memory reclamation (hazard pointers, epoch-based reclamation, ...)

type
  FlowEvent* = object
    ## A flow event represents a contract between
    ## a producer task that triggers or fires the event
    ## and a consumer dependent task that is deferred until the event is triggered.
    ##
    ## The difference with a Flowvar is that a FlowEvent represents
    ## a delayed input while a Flowvar represents a delayed result.
    ##
    ## FlowEvents enable the following parallelism paradigm known under the following names:
    ## - dataflow parallelism
    ## - graph parallelism
    ## - pipeline parallelism
    ## - data-driven task parallelism
    ## - stream parallelism
    e: EventPtr

  TaskNode = ptr object
    ## Task Metadata.
    task*: Task
    # Next task in the current event channel
    next: Atomic[pointer]
    # Next task dependency if it has multiple
    nextDep*: TaskNode
    event*: FlowEvent
    bucketID*: int32

  EventKind = enum
    Single
    Iteration

  EventIter = object
    numBuckets: int32
    start, stop, stride: int32
    singles: ptr UncheckedArray[SingleEvent]

  EventUnion {.union.} = object
    single: SingleEvent
    iter: EventIter

  EventPtr = ptr object
    refCount: Atomic[int32]
    kind: EventKind
    union: EventUnion

  SingleEvent = object
    # The MPSC Channel is intrusive to the SingleEvent.
    # The end fields in the channel should be the consumer
    # to limit cache-line conflicts with producer threads.
    chan: ChannelMpscUnboundedBatch[TaskNode, keepCount = false]
    deferredIn: Atomic[int32]
    deferredOut: Atomic[int32]
    triggered: Atomic[bool]

const NoIter* = -1

# Internal
# ----------------------------------------------------
# Refcounting is started from 0 and we avoid fetchSub with release semantics
# in the common case of only one reference being live.

proc `=destroy`*(event: var FlowEvent) =
  if event.e.isNil:
    return

  let count = event.e.refCount.load(moRelaxed)
  fence(moAcquire)
  if count == 0:
    # We have the last reference
    if not event.e.isNil:
      if event.e.kind == Iteration:
        wv_free(event.e.union.iter.singles)
      # Return memory to the memory pool
      recycle(event.e)
  else:
    discard fetchSub(event.e.refCount, 1, moRelease)
  event.e = nil

proc `=sink`*(dst: var FlowEvent, src: FlowEvent) {.inline.} =
  # Don't pay for atomic refcounting when compiler can prove there is no ref change
  `=destroy`(dst)
  system.`=sink`(dst.e, src.e)

proc `=`*(dst: var FlowEvent, src: FlowEvent) {.inline.} =
  `=destroy`(dst)
  discard fetchAdd(src.e.refCount, 1, moRelaxed)
  dst.e = src.e

# Multi-Dependencies FlowEvents
# ----------------------------------------------------

proc delayedUntilSingle(taskNode: TaskNode, curTask: Task): bool =
  ## Redelay a task that depends on multiple events
  ## with 1 or more events triggered but still some triggered.
  ##
  ## Returns `true` if the task has been delayed.
  ## The task should not be accessed anymore by the current worker.
  ## Returns `false` if the task can be scheduled right away by the current worker thread.
  preCondition: not taskNode.event.e.isNil
  preCondition: taskNode.event.e.kind == Single

  if taskNode.event.e.union.single.triggered.load(moRelaxed):
    fence(moAcquire)
    return false

  # Mutual exclusion / prevent races
  discard taskNode.event.e.union.single.deferredIn.fetchAdd(1, moRelaxed)

  if taskNode.event.e.union.single.triggered.load(moRelaxed):
    fence(moAcquire)
    discard taskNode.event.e.union.single.deferredOut.fetchAdd(1, moRelaxed)
    return false

  # Send the task to the event triggerer
  discard taskNode.event.e.union.single.chan.trySend(taskNode)
  discard taskNode.event.e.union.single.deferredOut.fetchAdd(1, moRelaxed)
  return true

proc delayedUntilIter(taskNode: TaskNode, curTask: Task): bool =
  ## Redelay a task that depends on multiple events
  ## with 1 or more events triggered but still some untriggered.
  ##
  ## Returns `true` if the task has been delayed.
  ## The task should not be accessed anymore by the current worker.
  ## Returns `false` if the task can be scheduled right away by the current worker thread.
  preCondition: not taskNode.event.e.isNil

  if taskNode.event.e.union.iter.singles[taskNode.bucketID].triggered.load(moRelaxed):
    fence(moAcquire)
    return false

  # Mutual exclusion / prevent races
  discard taskNode.event.e.union.iter.singles[taskNode.bucketID].deferredIn.fetchAdd(1, moRelaxed)

  if taskNode.event.e.union.iter.singles[taskNode.bucketID].triggered.load(moRelaxed):
    fence(moAcquire)
    discard taskNode.event.e.union.iter.singles[taskNode.bucketID].deferredOut.fetchAdd(1, moRelaxed)
    return false

  # Send the task to the event triggerer
  discard taskNode.event.e.union.iter.singles[taskNode.bucketID].chan.trySend(taskNode)
  discard taskNode.event.e.union.iter.singles[taskNode.bucketID].deferredOut.fetchAdd(1, moRelaxed)
  return true

proc delayedUntil(taskNode: TaskNode, curTask: Task): bool =
  ## Redelay a task that depends on multiple events (in the `taskNode` linked list)
  ## with 1 or more events triggered but still some untriggered.
  ##
  ## Returns `true` if the task has been delayed.
  ## The task should not be accessed anymore by the current worker.
  ## Returns `false` if the task can be scheduled right away by the current worker thread.
  preCondition: not taskNode.event.e.isNil
  preCondition: bool(taskNode.task == curTask)
  if taskNode.event.e.kind == Single:
    delayedUntilSingle(taskNode, curTask)
  else:
    delayedUntilIter(taskNode, curTask)

# Public - single task event
# ----------------------------------------------------

proc initialize*(event: var FlowEvent, pool: var TLPoolAllocator) =
  ## Initialize a FlowEvent.
  ## Tasks can depend on an event and in that case their scheduling
  ## will be delayed until that event is triggered.
  ## This allows modelling precise data dependencies.
  preCondition: event.e.isNil
  event.e = pool.borrow0(deref(EventPtr))
  event.e.kind = Single
  event.e.union.single.chan.initialize()

proc delayedUntil*(task: Task, event: FlowEvent, pool: var TLPoolAllocator): bool =
  ## Defers a task until an event is triggered
  ##
  ## Returns `true` if the task has been delayed.
  ## The task should not be accessed anymore by the current worker.
  ## Returns `false` if the task can be scheduled right away by the current worker thread.
  preCondition: not event.e.isNil
  preCondition: event.e.kind == Single

  # Optimization to avoid paying the cost of atomics
  if event.e.union.single.triggered.load(moRelaxed):
    fence(moAcquire)
    return false

  # Mutual exclusion / prevent races
  discard event.e.union.single.deferredIn.fetchAdd(1, moRelaxed)

  if event.e.union.single.triggered.load(moRelaxed):
    fence(moAcquire)
    discard event.e.union.single.deferredOut.fetchAdd(1, moRelaxed)
    return false

  # Send the task to the event triggerer
  let taskNode = pool.borrow0(deref(TaskNode))
  taskNode.task = task
  taskNode.bucketID = NoIter
  # Don't need to store the event reference if there is only the current one
  discard event.e.union.single.chan.trySend(taskNode)
  discard event.e.union.single.deferredOut.fetchAdd(1, moRelaxed)
  return true

template triggerImpl*(event: FlowEvent, queue, enqueue: typed) =
  ## A producer thread triggers an event.
  ## An event can only be triggered once.
  ## A producer will immediately scheduled all tasks dependent on that event
  ## unless they also depend on another untriggered event.
  ## Dependent tasks scheduled at a later time will be scheduled immediately
  ##
  ## `queue` is the data structure for ready tasks
  ## `enqueue` is the correspondig enqueing proc
  ## This should be wrapped in a proc to avoid code-bloat as the template is big
  preCondition: not event.e.isNil
  preCondition: event.e.kind == Single
  preCondition: not load(event.e.union.single.triggered, moRelaxed)

  # Lock the event, new tasks should be scheduled right away
  fence(moRelease)
  store(event.e.union.single.triggered, true, moRelaxed)

  # TODO: some state machine here?
  while true:
    var task: Task
    var taskNode: TaskNode
    while event.e.union.single.chan.tryRecv(taskNode):
      ascertain: not taskNode.isNil
      ascertain: taskNode.bucketID == NoIter
      task = taskNode.task
      var wasDelayed = false
      while not taskNode.nextDep.isNil:
        if delayedUntil(taskNode, task):
          wasDelayed = true
          break
        let depNode = taskNode.nextDep
        recycle(taskNode)
        taskNode = depNode
      if not wasDelayed:
        enqueue(queue, task)
        recycle(taskNode)

    # Restart if an event producer didn't finish delaying a task
    if load(event.e.union.single.deferredOut, moAcquire) != load(event.e.union.single.deferredIn, moAcquire):
      cpuRelax()
    else:
      break

# Public - iteration task event
# ----------------------------------------------------

proc initialize*(event: var FlowEvent, pool: var TLPoolAllocator, start, stop, stride: int32) =
  ## Initialize an event for iteration tasks

  preCondition: stop > start
  preCondition: stride > 0
  preCondition: event.e.isNil

  event.e = pool.borrow0(deref(EventPtr))
  # We start refcount at 0
  event.e.kind = Iteration
  event.e.union.iter.numBuckets = (stop - start + stride-1) div stride
  event.e.union.iter.start = start
  event.e.union.iter.stop = stop
  event.e.union.iter.stride = stride

  # The mempool doesn't support arrays
  event.e.union.iter.singles = wv_alloc(SingleEvent, event.e.union.iter.numBuckets)
  zeroMem(event.e.union.iter.singles, event.e.union.iter.numBuckets * sizeof(SingleEvent))

  for i in 0 ..< event.e.union.iter.numBuckets:
    event.e.union.iter.singles[i].chan.initialize()

proc getBucket(event: FlowEvent, index: int32): int32 {.inline.} =
  ## Convert a possibly offset and/or strided for-loop iteration index
  ## to an event bucket in the range [0, numBuckets)
  preCondition: index in event.e.union.iter.start ..< event.e.union.iter.stop
  result = (index - event.e.union.iter.start) div event.e.union.iter.stride

proc delayedUntil*(task: Task, event: FlowEvent, index: int32, pool: var TLPoolAllocator): bool =
  ## Defers a task until an event[index] is triggered
  ##
  ## Returns `true` if the task has been delayed.
  ## The task should not be accessed anymore by the current worker.
  ## Returns `false` if the task can be scheduled right away by the current worker thread.
  preCondition: not event.e.isNil
  preCondition: event.e.kind == Iteration

  let bucket = event.getBucket(index)

  # Optimization to avoid paying the cost of atomics
  if event.e.union.iter.singles[bucket].triggered.load(moRelaxed):
    fence(moAcquire)
    return false

  # Mutual exclusion / prevent races
  discard event.e.union.iter.singles[bucket].deferredIn.fetchAdd(1, moRelaxed)

  if event.e.union.iter.singles[bucket].triggered.load(moRelaxed):
    fence(moAcquire)
    discard event.e.union.iter.singles[bucket].deferredOut.fetchAdd(1, moRelaxed)
    return false

  # Send the task to the event triggerer
  let taskNode = pool.borrow0(deref(TaskNode))
  taskNode.task = task
  # Don't need to store the event reference if there is only the current one
  taskNode.bucketID = bucket
  discard event.e.union.iter.singles[bucket].chan.trySend(taskNode)
  discard event.e.union.iter.singles[bucket].deferredOut.fetchAdd(1, moRelaxed)
  return true

template triggerIterImpl*(event: FlowEvent, index: int32, queue, enqueue: typed) =
  ## A producer thread triggers an event.
  ## An event can only be triggered once.
  ## A producer will immediately scheduled all tasks dependent on that event
  ## unless they also depend on another untriggered event.
  ## Dependent tasks scheduled at a later time will be scheduled immediately
  ##
  ## `queue` is the data structure for ready tasks
  ## `enqueue` is the correspondig enqueing proc
  ## This should be wrapped in a proc to avoid code-bloat as the template is big
  preCondition: not event.e.isNil
  preCondition: event.e.kind == Iteration

  let bucket = getBucket(event, index)
  preCondition: not load(event.e.union.iter.singles[bucket].triggered, moRelaxed)

  # Lock the event, new tasks should be scheduled right away
  fence(moRelease)
  store(event.e.union.iter.singles[bucket].triggered, true, moRelaxed)

  # TODO: some state machine here?
  while true:
    var task {.inject.}: Task
    var taskNode: TaskNode
    while event.e.union.iter.singles[bucket].chan.tryRecv(taskNode):
      ascertain: not taskNode.isNil
      ascertain: taskNode.bucketID != NoIter
      task = taskNode.task
      var wasDelayed = false
      while not taskNode.nextDep.isNil:
        if delayedUntil(taskNode, task):
          wasDelayed = true
          break
        let depNode = taskNode.nextDep
        recycle(taskNode)
        taskNode = depNode
      if not wasDelayed:
        enqueue(queue, task)
        recycle(taskNode)

    # Restart if an event producer didn't finish delaying a task
    if load(event.e.union.iter.singles[bucket].deferredOut, moAcquire) != load(event.e.union.iter.singles[bucket].deferredIn, moAcquire):
      cpuRelax()
    else:
      break

# Multiple dependencies
# ------------------------------------------------------------------------------

macro delayedUntilMulti*(task: Task, pool: var TLPoolAllocator, events: varargs[untyped]): untyped =
  ## Associate a task with multiple dependencies
  result = newStmtList()

  var taskNodesInitStmt = newStmtList()
  var firstNode, prevNode: NimNode
  for i in 0 ..< events.len:
    var taskNode: NimNode
    var taskNodeInit = newStmtList()
    if events[i].kind == nnkPar:
      let event = events[i][0]
      taskNode = genSym(nskLet, "taskNode_" & $event[i] & "_" & $events[i][1] & "_")
      let bucket = newCall(bindSym"getBucket", event, events[i][1])
      taskNodeInit.add quote do:
        let `taskNode` = borrow0(`pool`, deref(TaskNode))
        `taskNode`.task = `task`
        `taskNode`.event = `event`
        `taskNode`.bucketID = `bucket`
    else:
      taskNode = genSym(nskLet, "taskNode_" & $events[i] & "_")
      let event = events[i]
      taskNodeInit.add quote do:
        let `taskNode` = borrow0(`pool`, deref(TaskNode))
        `taskNode`.task = `task`
        `taskNode`.event = `event`
        `taskNode`.bucketID = NoIter
    if i != 0:
      taskNodeInit.add quote do:
        `taskNode`.nextDep = `prevNode`
    else:
      taskNodeInit.add quote do:
        `taskNode`.nextDep = nil
      firstNode = taskNode
    prevnode = taskNode
    taskNodesInitStmt.add taskNodeInit

  result.add taskNodesInitStmt
  result.add newCall(bindSym"delayedUntil", firstNode, task)

# Sanity checks
# ------------------------------------------------------------------------------

debugSizeAsserts:
  when sizeof(pointer) == 8:
    let expectedSize = 40
  else:
    let expectedSize = 20
  doAssert sizeof(default(TaskNode)[]) == expectedSize,
    "TaskNode size was " & $sizeof(default(TaskNode)[])

  doAssert sizeof(ChannelMpscUnboundedBatch[TaskNode, false]) == 128,
    "MPSC channel size was " & $sizeof(ChannelMpscUnboundedBatch[TaskNode, false])

  doAssert sizeof(SingleEvent) == 192,
    "SingleEvent size was " & $sizeof(SingleEvent)

  doAssert sizeof(default(EventPtr)[]) <= WV_MemBlockSize,
    "EventPtr object size was " & $sizeof(default(EventPtr)[])

when isMainModule:
  type TaskStack = object
    top: Task
    count: int

  proc add(stack: var TaskStack, task: sink Task) =
    task.next = stack.top
    stack.top = task
    stack.count += 1

  proc pop(stack: var TaskStack): Task =
    result = stack.top
    stack.top = stack.top.next
    stack.count -= 1

    doAssert:
      if result.isNil: stack.count == 0
      else: true

  var pool: TLPoolAllocator
  pool.initialize()

  proc mainSingle() =
    var stack: TaskStack

    var event1: FlowEvent
    event1.initialize(pool)
    block: # FlowEvent 1
      let task = wv_allocPtr(Task, zero = true)
      let delayed = task.delayedUntil(event1, pool)
      doAssert delayed

    doAssert stack.count == 0

    event1.triggerImpl(stack, add)

    doAssert stack.count == 1

    block: # FlowEvent 1 - late
      let task = wv_allocPtr(Task, zero = true)

      let delayed = task.delayedUntil(event1, pool)
      doAssert not delayed

    doAssert stack.count == 1 # enqueuing is left as an exercise to the late thread.

    var event2: FlowEvent
    event2.initialize(pool)
    block:
      block:
        let task = wv_allocPtr(Task, zero = true)
        let delayed = task.delayedUntil(event2, pool)
        doAssert delayed
      block:
        let task = wv_allocPtr(Task, zero = true)
        let delayed = task.delayedUntil(event2, pool)
        doAssert delayed

    doAssert stack.count == 1
    event2.triggerImpl(stack, add)
    doAssert stack.count == 3

    echo "Simple event: SUCCESS"

  mainSingle()

  proc mainLoop() =
    var stack: TaskStack

    var event1: FlowEvent
    event1.initialize(pool, 0, 10, 1)
    block: # FlowEvent 1
      let task = wv_allocPtr(Task, zero = true)
      let delayed = task.delayedUntil(event1, 3, pool)
      doAssert delayed

    doAssert stack.count == 0

    event1.triggerIterImpl(3, stack, add)

    doAssert stack.count == 1

    block: # FlowEvent 1 - late
      let task = wv_allocPtr(Task, zero = true)

      let delayed = task.delayedUntil(event1, 3, pool)
      doAssert not delayed

    doAssert stack.count == 1 # enqueuing is left as an exercise to the late thread.

    var event2: FlowEvent
    event2.initialize(pool, 0, 10, 1)
    block:
      block:
        let task = wv_allocPtr(Task, zero = true)
        let delayed = task.delayedUntil(event2, 4, pool)
        doAssert delayed
      block:
        let task = wv_allocPtr(Task, zero = true)
        let delayed = task.delayedUntil(event2, 4, pool)
        doAssert delayed

    doAssert stack.count == 1
    event2.triggerIterImpl(4, stack, add)
    doAssert stack.count == 3

    echo "Loop event: SUCCESS"

  mainLoop()
