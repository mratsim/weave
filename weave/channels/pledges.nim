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
  ../instrumentation/contracts,
  ../config

# Pledges
# ----------------------------------------------------
# Pledges are the counterpart to Flowvar.
#
# When a task depends on a pledge, it is delayed until the pledge is fulfilled
# This allows to model precise dependencies between tasks
# beyond what traditional control-flow dependencies (function calls, barriers, locks) allow.
#
# Furthermore control-flow dependencies like barriers and locks suffer from:
# - composability problem (barriers are incompatible with work stealing or nested parallelism).
# - restrict the parallelism exposed.
# - expose the programmers to concurrency woes that could be avoided
#   by specifying precede/after relationship
#
# This data availabity based parallelism is also called:
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
# A pledge is an ownerless MPSC channel that holds tasks.
# The number of tasks in the channel is bounded by the number of dependent tasks
# When a worker fulfills a pledge, it becomes the unique consumer of the MPSC channel.
# It flags the pledge as fullfilled and drain the channel of all tasks.
# When a task is dependent on a pledge, the worker that received the dependent task
# checks the fulfilled flag.
# Case 1: It is fulfilled, it schedules the task as a normal task
# Case 2: It is not fulfilled, it sends the task in the pledge MPSC channel.
#
# Tasks with multiple dependencies are represented by a list of pledges
# When a task is enqueued, it is sent to one of the unfulfilled pledge channel at random
# When that pledge is fulfilled, if all other pladges are fulfiled, it can be scheduled immediately
# Otherwise it is sent to one of the unfilfilled pledge at random.
#
# Memory management is done through atomic reference counting.
# Pledges for loop iterations can use a single reference count for all iterations,
# however each iteration should have its pledge channel. This has a memory cost,
# users should be encouraged to use tiling/blocking.
#
# Mutual exclusion
# There is a race if a producer worker delivers on the pledge and a consumer
# checks the pledge status.
# In our case, the fulfilled flag is write-once, the producer worker only requires
# a way to know if a data race could have occurred.
#
# The pledge keeps 2 monotonically increasing atomic count of consumers in and consumers out
# When a consumer checks the pledge:
# - it increments the consumer count "in"
# - on exit it always increments the consumer count "out"
# - if it's fulfilled, increments the consumer count "out",
#   then exits and schedule the task itself
# - if it's not, it enqueues the task
#   Then increments the count out
# - The producer thread checks after draining all tasks that the consumer in/out counts are the same
#   otherwise it needs to drain again until it is sure that the consumer is out.
# Keeping 2 count avoids the ABA problem.
# Pledges are allocated from memory pool blocks of size 2x WV_CacheLinePadding (256 bytes)
# with an intrusive MPSC channel
#
# Analysis:
# This protocol avoids latency between when the data is ready and when the task is scheduled
# exposing the maximum amount of parallelism.
# Proof: As soon as the pledge is fulfilled, any dependent tasks are scheduled
#        or the task was not yet created. In tasks created late is scheduled by the creating worker.
#
# This protocol minimizes the number of message sent. There is at most 1 per dependencies unlike
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
# to map Pledge=>seq[Task] and Task=>seq[Pledge] to quickly obtain
# all tasks that can be scheduled from a resolved pledge and
# to track the multiple dependencies a task can have.
#
# In particular this play well with the custom memory pool of Weave, unlike Nim sequences or hash-tables.
#
# This protocol is cache friendly. The deferred task is co-located with the producer pledge.
# When scheduled, it will use data hot in cache unless task is stolen but it can only be stolen if it's the
# only task left due to LIFO work and FIFO thefts.
#
# This protocol doesn't impose ordering on the producer and consumer (pledge fulfiller and pledge dependent task).
# Other approaches might lead to missed messages unless they introduce state/memory,
# which is always complex in "distributed" long-lived computations due to memory reclamation (hazard pointers, epoch-based reclamation, ...)

type
  Pledge* = object
    ## A pledge represents a contract between
    ## a producer task that fulfills or deliver on the pledge
    ## and a consumer dependent task that is deferred until the pledge is fulfilled.
    ##
    ## The difference with a Flowvar is that a Pledge represents
    ## a delayed input while a Flowvar represents a delayed result.
    ##
    ## Pledge enables the following parallelism paradigm known under the following names:
    ## - dataflow parallelism
    ## - graph parallelism
    ## - pipeline parallelism
    ## - data-driven task parallelism
    ## - stream parallelism
    ##
    ## In particular, this is the only way to implement a "barrier" compatible
    ## with a work-stealing scheduler that can be composed and nested in parallel regions
    ## that an unknown number of workers will execute.
    p: PledgePtr

  TaskNode = ptr object
    ## Task Metadata.
    task*: Task
    # Next task in the current pledge channel
    next: Atomic[pointer]
    # Next task dependency if it has multiple
    nextDep*: TaskNode
    pledge*: Pledge
    bucketID*: int32

  PledgeKind = enum
    Single
    Iteration

  PledgePtr = ptr object
    refCount: Atomic[int32]
    case kind: PledgeKind
    of Single:
      impl: PledgeImpl
    of Iteration:
      numBuckets: int32
      start, stop, stride: int32
      impls: ptr UncheckedArray[PledgeImpl]

  PledgeImpl = object
    # Issue: https://github.com/mratsim/weave/issues/93
    # TODO, the current MPSC channel always use a "count" field.
    #   Contrary to StealRequest and the remote freed memory in the memory pool,
    #   this is not needed, and atomics are expensive.
    #   It can be made optional with a useCount static bool.

    # The MPSC Channel is intrusive to the PledgeImpl.
    # The end fields in the channel should be the consumer
    # to avoid cache-line conflicts with producer threads.
    chan: ChannelMpscUnboundedBatch[TaskNode]
    deferredIn: Atomic[int32]
    deferredOut: Atomic[int32]
    fulfilled: Atomic[bool]

const NoIter* = -1

# Internal
# ----------------------------------------------------
# Refcounting is started from 0 and we avoid fetchSub with release semantics
# in the common case of only one reference being live.

proc `=destroy`*(pledge: var Pledge) =
  if pledge.p.isNil:
    return

  let count = pledge.p.refCount.load(moRelaxed)
  fence(moAcquire)
  if count == 0:
    # We have the last reference
    if not pledge.p.isNil:
      if pledge.p.kind == Iteration:
        wv_free(pledge.p.impls)
      # Return memory to the memory pool
      recycle(pledge.p)
  else:
    discard fetchSub(pledge.p.refCount, 1, moRelease)
  pledge.p = nil

proc `=sink`*(dst: var Pledge, src: Pledge) {.inline.} =
  # Don't pay for atomic refcounting when compiler can prove there is no ref change
  # `=destroy`(dst) # it seems like we can have non properly init types?
                    # with the pointer not being nil, but invalid as well
  system.`=sink`(dst.p, src.p)

proc `=`*(dst: var Pledge, src: Pledge) {.inline.} =
  discard fetchAdd(src.p.refCount, 1, moRelaxed)
  dst.p = src.p

# Multi-Dependencies pledges
# ----------------------------------------------------

proc delayedUntilSingle(taskNode: TaskNode, curTask: Task): bool =
  ## Redelay a task that depends on multiple pledges
  ## with 1 or more pledge fulfilled but still some unfulfilled.
  ## field is a place holder for impl / impls[bucket]
  preCondition: not taskNode.pledge.p.isNil

  if taskNode.pledge.p.impl.fulfilled.load(moRelaxed):
    fence(moAcquire)
    return false

  # Mutual exclusion / prevent races
  discard taskNode.pledge.p.impl.deferredIn.fetchAdd(1, moRelaxed)

  if taskNode.pledge.p.impl.fulfilled.load(moRelaxed):
    fence(moAcquire)
    discard taskNode.pledge.p.impl.deferredOut.fetchAdd(1, moRelaxed)
    return false

  # Send the task to the pledge fulfiller
  taskNode.task = curTask
  let pledge = taskNode.pledge
  taskNode.pledge = default(Pledge)
  discard pledge.p.impl.chan.trySend(taskNode)
  discard pledge.p.impl.deferredOut.fetchAdd(1, moRelaxed)
  return true

proc delayedUntilIter(taskNode: TaskNode, curTask: Task): bool =
  ## Redelay a task that depends on multiple pledges
  ## with 1 or more pledge fulfilled but still some unfulfilled.
  ## field is a place holder for impl / impls[bucket]
  preCondition: not taskNode.pledge.p.isNil

  if taskNode.pledge.p.impls[taskNode.bucketID].fulfilled.load(moRelaxed):
    fence(moAcquire)
    return false

  # Mutual exclusion / prevent races
  discard taskNode.pledge.p.impls[taskNode.bucketID].deferredIn.fetchAdd(1, moRelaxed)

  if taskNode.pledge.p.impls[taskNode.bucketID].fulfilled.load(moRelaxed):
    fence(moAcquire)
    discard taskNode.pledge.p.impls[taskNode.bucketID].deferredOut.fetchAdd(1, moRelaxed)
    return false

  # Send the task to the pledge fulfiller
  taskNode.task = curTask
  let pledge = taskNode.pledge
  taskNode.pledge = default(Pledge)
  discard pledge.p.impls[taskNode.bucketID].chan.trySend(taskNode)
  discard pledge.p.impls[taskNode.bucketID].deferredOut.fetchAdd(1, moRelaxed)
  return true

proc delayedUntil*(taskNode: TaskNode, curTask: Task): bool =
  ## Redelay a task that depends on multiple pledges
  ## with 1 or more pledge fulfilled but still some unfulfilled.
  preCondition: not taskNode.pledge.p.isNil
  if taskNode.pledge.p.kind == Single:
    delayedUntilSingle(taskNode, curTask)
  else:
    delayedUntilIter(taskNode, curTask)

# Public - single task pledge
# ----------------------------------------------------

proc initialize*(pledge: var Pledge, pool: var TLPoolAllocator) =
  ## Initialize a pledge.
  ## Tasks can depend on a pledge and in that case their scheduling
  ## will be delayed until that pledge is fulfilled.
  ## This allows modelling precise data dependencies.
  preCondition: pledge.p.isNil
  pledge.p = pool.borrow(deref(PledgePtr))
  zeroMem(pledge.p, sizeof(deref(PledgePtr))) # We start the refCount at 0
  # TODO: mempooled MPSC channel https://github.com/mratsim/weave/issues/93
  pledge.p.kind = Single
  pledge.p.impl.chan.initialize()

proc delayedUntil*(task: Task, pledge: Pledge, pool: var TLPoolAllocator): bool =
  ## Defers a task until a pledge is fulfilled
  ## Returns true if the task has been delayed.
  ## The task should not be accessed anymore
  ## Returns false if the task can be scheduled right away.
  preCondition: not pledge.p.isNil
  preCondition: pledge.p.kind == Single

  # Optimization to avoid paying the cost of atomics
  if pledge.p.impl.fulfilled.load(moRelaxed):
    fence(moAcquire)
    return false

  # Mutual exclusion / prevent races
  discard pledge.p.impl.deferredIn.fetchAdd(1, moRelaxed)

  if pledge.p.impl.fulfilled.load(moRelaxed):
    fence(moAcquire)
    discard pledge.p.impl.deferredOut.fetchAdd(1, moRelaxed)
    return false

  # Send the task to the pledge fulfiller
  let taskNode = pool.borrow(deref(TaskNode))
  taskNode.task = task
  taskNode.next.store(nil, moRelaxed)
  taskNode.pledge = default(Pledge) # Don't need to store the pledge reference if there is only the current one
  taskNode.bucketID = NoIter
  discard pledge.p.impl.chan.trySend(taskNode)
  discard pledge.p.impl.deferredOut.fetchAdd(1, moRelaxed)
  return true

template fulfillImpl*(pledge: Pledge, queue, enqueue: typed) =
  ## A producer thread fulfills a pledge.
  ## A pledge can only be fulfilled once.
  ## A producer will immediately scheduled all tasks dependent on that pledge
  ## unless they also depend on another unfulfilled pledge.
  ## Dependent tasks scheduled at a later time will be scheduled immediately
  ##
  ## `queue` is the data structure for ready tasks
  ## `enqueue` is the correspondig enqueing proc
  ## This should be wrapped in a proc to avoid code-bloat as the template is big
  preCondition: not pledge.p.isNil
  preCondition: pledge.p.kind == Single
  preCondition: not load(pledge.p.impl.fulfilled, moRelaxed)

  # Lock the pledge, new tasks should be scheduled right away
  fence(moRelease)
  store(pledge.p.impl.fulfilled, true, moRelaxed)

  # TODO: some state machine here?
  while true:
    var task: Task
    var taskNode: TaskNode
    while pledge.p.impl.chan.tryRecv(taskNode):
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

    if load(pledge.p.impl.deferredOut, moAcquire) != load(pledge.p.impl.deferredIn, moAcquire):
      cpuRelax()
    else:
      break

# Public - iteration task pledge
# ----------------------------------------------------

proc initialize*(pledge: var Pledge, pool: var TLPoolAllocator, start, stop, stride: int32) =
  ## Initialize a pledge for iteration tasks

  preCondition: stop > start
  preCondition: stride > 0
  preCondition: pledge.p.isNil

  pledge.p = pool.borrow(deref(PledgePtr))
  # We start refcount at 0 - and the need to workaround case object value change is a huge pain
  pledge.p[] = deref(PledgePtr)(
    kind: Iteration,
    numBuckets: (stop - start + stride-1) div stride,
    start: start,
    stop: stop,
    stride: stride
  )

  # The mempool doesn't support arrays
  pledge.p.impls = wv_alloc(PledgeImpl, pledge.p.numBuckets)
  zeroMem(pledge.p.impls, pledge.p.numBuckets * sizeof(PledgeImpl))

  for i in 0 ..< pledge.p.numBuckets:
    pledge.p.impls[i].chan.initialize()

proc getBucket(pledge: Pledge, index: int32): int32 {.inline.} =
  ## Convert a possibly offset and/or strided for-loop iteration index
  ## to a pledge bucket in the range [0, numBuckets)
  preCondition: index in pledge.p.start ..< pledge.p.stop
  result = (index - pledge.p.start) div pledge.p.stride

proc delayedUntil*(task: Task, pledge: Pledge, index: int32, pool: var TLPoolAllocator): bool =
  ## Defers a task until a pledge[index] is fulfilled
  ## Returns true if the task has been delayed.
  ## The task should not be accessed anymore
  ## Returns false if the task can be scheduled right away.
  preCondition: not pledge.p.isNil
  preCondition: pledge.p.kind == Iteration

  let bucket = pledge.getBucket(index)

  # Optimization to avoid paying the cost of atomics
  if pledge.p.impls[bucket].fulfilled.load(moRelaxed):
    fence(moAcquire)
    return false

  # Mutual exclusion / prevent races
  discard pledge.p.impls[bucket].deferredIn.fetchAdd(1, moRelaxed)

  if pledge.p.impls[bucket].fulfilled.load(moRelaxed):
    fence(moAcquire)
    discard pledge.p.impls[bucket].deferredOut.fetchAdd(1, moRelaxed)
    return false

  # Send the task to the pledge fulfiller
  let taskNode = pool.borrow(deref(TaskNode))
  taskNode.task = task
  taskNode.next.store(nil, moRelaxed)
  taskNode.pledge = default(Pledge) # Don't need to store the pledge reference if there is only the current one
  taskNode.bucketID = bucket
  discard pledge.p.impls[bucket].chan.trySend(taskNode)
  discard pledge.p.impls[bucket].deferredOut.fetchAdd(1, moRelaxed)
  return true

template fulfillIterImpl*(pledge: Pledge, index: int32, queue, enqueue: typed) =
  ## A producer thread fulfills a pledge.
  ## A pledge can only be fulfilled once.
  ## A producer will immediately scheduled all tasks dependent on that pledge
  ## unless they also depend on another unfulfilled pledge.
  ## Dependent tasks scheduled at a later time will be scheduled immediately
  ##
  ## `queue` is the data structure for ready tasks
  ## `enqueue` is the correspondig enqueing proc
  ## This should be wrapped in a proc to avoid code-bloat as the template is big
  preCondition: not pledge.p.isNil
  preCondition: pledge.p.kind == Iteration

  let bucket = getBucket(pledge, index)
  preCondition: not load(pledge.p.impls[bucket].fulfilled, moRelaxed)

  # Lock the pledge, new tasks should be scheduled right away
  fence(moRelease)
  store(pledge.p.impls[bucket].fulfilled, true, moRelaxed)

  # TODO: some state machine here?
  while true:
    var task {.inject.}: Task
    var taskNode: TaskNode
    while pledge.p.impls[bucket].chan.tryRecv(taskNode):
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

    if load(pledge.p.impls[bucket].deferredOut, moAcquire) != load(pledge.p.impls[bucket].deferredIn, moAcquire):
      cpuRelax()
    else:
      break

# Multiple dependencies
# ------------------------------------------------------------------------------

macro delayedUntilMulti*(task: Task, pool: var TLPoolAllocator, pledges: varargs[untyped]): untyped =
  ## Associate a task with multiple dependencies
  result = newStmtList()

  var taskNodesInitStmt = newStmtList()
  var firstNode, prevNode: NimNode
  for i in 0 ..< pledges.len:
    var taskNode: NimNode
    var taskNodeInit = newStmtList()
    if pledges[i].kind == nnkPar:
      let pledge = pledges[i][0]
      taskNode = genSym(nskLet, "taskNode_" & $pledge[i] & "_" & $pledges[i][1] & "_")
      let bucket = newCall(bindSym"getBucket", pledge, pledges[i][1])
      taskNodeInit.add quote do:
        let `taskNode` = borrow(`pool`, deref(TaskNode))
        `taskNode`.task = `task`
        `taskNode`.pledge = `pledge`
        `taskNode`.bucketID = `bucket`
    else:
      taskNode = genSym(nskLet, "taskNode_" & $pledges[i] & "_")
      let pledge = pledges[i]
      taskNodeInit.add quote do:
        let `taskNode` = borrow(`pool`, deref(TaskNode))
        `taskNode`.task = `task`
        `taskNode`.pledge = `pledge`
        `taskNode`.bucketID = NoIter
    if i != 0:
      taskNodeInit.add quote do:
        `taskNode`.nextDep = `prevNode`
    else:
      firstNode = taskNode
    prevnode = taskNode
    taskNodesInitStmt.add taskNodeInit

  result.add taskNodesInitStmt
  result.add newCall(bindSym"delayedUntil", firstNode, task)

# Sanity checks
# ------------------------------------------------------------------------------

when sizeof(pointer) == 8:
  let expectedSize = 40
else:
  let expectedSize = 20
assert sizeof(default(TaskNode)[]) == expectedSize,
  "TaskNode size was " & $sizeof(default(TaskNode)[])

assert sizeof(ChannelMpscUnboundedBatch[TaskNode]) == 128,
  "MPSC channel size was " & $sizeof(ChannelMpscUnboundedBatch[TaskNode])

assert sizeof(PledgeImpl) == 192,
  "PledgeImpl size was " & $sizeof(PledgeImpl)

assert sizeof(default(PledgePtr)[]) <= WV_MemBlockSize,
  "PledgePtr object size was " & $sizeof(default(PledgePtr)[])

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

    var pledge1: Pledge
    pledge1.initialize(pool)
    block: # Pledge 1
      let task = wv_allocPtr(Task, zero = true)
      let delayed = task.delayedUntil(pledge1, pool)
      doAssert delayed

    doAssert stack.count == 0

    pledge1.fulfillImpl(stack, add)

    doAssert stack.count == 1

    block: # Pledge 1 - late
      let task = wv_allocPtr(Task, zero = true)

      let delayed = task.delayedUntil(pledge1, pool)
      doAssert not delayed

    doAssert stack.count == 1 # enqueuing is left as an exercise to the late thread.

    var pledge2: Pledge
    pledge2.initialize(pool)
    block:
      block:
        let task = wv_allocPtr(Task, zero = true)
        let delayed = task.delayedUntil(pledge2, pool)
        doAssert delayed
      block:
        let task = wv_allocPtr(Task, zero = true)
        let delayed = task.delayedUntil(pledge2, pool)
        doAssert delayed

    doAssert stack.count == 1
    pledge2.fulfillImpl(stack, add)
    doAssert stack.count == 3

  mainSingle()

  proc mainLoop() =
    var stack: TaskStack

    var pledge1: Pledge
    pledge1.initialize(pool, 0, 10, 1)
    block: # Pledge 1
      let task = wv_allocPtr(Task, zero = true)
      let delayed = task.delayedUntil(pledge1, 3, pool)
      doAssert delayed

    doAssert stack.count == 0

    pledge1.fulfillIterImpl(3, stack, add)

    doAssert stack.count == 1

    block: # Pledge 1 - late
      let task = wv_allocPtr(Task, zero = true)

      let delayed = task.delayedUntil(pledge1, 3, pool)
      doAssert not delayed

    doAssert stack.count == 1 # enqueuing is left as an exercise to the late thread.

    var pledge2: Pledge
    pledge2.initialize(pool, 0, 10, 1)
    block:
      block:
        let task = wv_allocPtr(Task, zero = true)
        let delayed = task.delayedUntil(pledge2, 4, pool)
        doAssert delayed
      block:
        let task = wv_allocPtr(Task, zero = true)
        let delayed = task.delayedUntil(pledge2, 4, pool)
        doAssert delayed

    doAssert stack.count == 1
    pledge2.fulfillIterImpl(4, stack, add)
    doAssert stack.count == 3

  mainLoop()
