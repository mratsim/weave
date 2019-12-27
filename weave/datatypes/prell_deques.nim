# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import ../instrumentation/[contracts, loggers]

type
  StealableTask* = concept task, var mutTask, type T
    ## task is a ptr object and has a next/prev field
    ## for intrusive doubly-linked list based deque
    task is ptr
    task.prev is T
    task.next is T
    # A task has a parent field
    task.parent is T
    # task has a "fn" field with the proc to run
    task.fn is proc (param: pointer) {.nimcall.}

    # TODO: checkout the liftLocal macro
    #       to reimplement closures and allow
    #
    # var myArray: ptr UncheckedArray[int]
    # parallel_loop(i, 0, 100000):
    #   myArray[i] = i
    #
    # with "myArray" implicitly captured.

  PrellDeque*[T: StealableTask] = object
    ## Private Intrusive Work-Stealing Deque
    ## from PhD Thesis
    ##
    ## Embracing Explicit Communication in Work-Stealing Runtime Systems
    ## Andreas Prell, 2016
    ## https://epub.uni-bayreuth.de/2990/1/main_final.pdf
    ##
    ## This is a thread-local work-stealing deque (unlike concurrent Chase-Lev deque)
    ## for multithreading runtimes that do not use shared-memory
    ## for inter-thread communication.
    ##
    ## PrellDeque implements the traditional work-stealing deque:
    ## - (push)
    ## - (pop)
    ## - (steal)
    ## Note that instead of pushing/pop-ing from the end
    ## and stealing from the start,
    ## PrellDeques push/pop from the start and steal from the end
    ##
    ## However as there is no thread contention, it also provides several extras:
    ## - adding multiple tasks at once
    ## - stealing one, half or an arbitrary number in-between
    ## - No need for complex formal verification of the deque
    ##   Formal verification and testing of queues is much more common.
    ##
    ## Channels/concurrent queues have much more research than
    ## concurrent deque and larger hardware support as they don't require atomics.
    ## Some hardware even provides message passing primitives.
    ##
    ## Channels also scale to clusters, as they are the only way to communicate
    ## between 2 machines (like MPI).
    ##
    ## The main drawback is the need to poll the communication channel, introducing latency,
    ## and requiring a backoff mechanism.
    pendingTasks*: range[0'i32 .. high(int32)]
    head: T
    tail: typeof(default(T)[])

# Basic routines
# ---------------------------------------------------------------

func isEmpty*(dq: PrellDeque): bool {.inline.} =
  # when empty dq.head == dq.tail == dummy node
  (dq.head == dq.tail.unsafeAddr) and (dq.pendingTasks == 0)

func addFirst*[T](dq: var PrellDeque[T], task: sink T) {.inline.} =
  ## Prepend a task to the beginning of the deque
  preCondition: not task.isNil

  task.next = dq.head
  dq.head.prev = task
  dq.head = task

  dq.pendingTasks += 1

func popFirst*[T](dq: var PrellDeque[T]): T {.inline.} =
  ## Pop the first task from the deque
  if dq.isEmpty():
    return nil

  result = dq.head
  dq.head = dq.head.next
  dq.head.prev = nil

  dq.pendingTasks -= 1

# Creation / Destruction
# ---------------------------------------------------------------

proc initialize*[T: StealableTask](dq: var PrellDeque[T]) {.inline.} =
  dq.head = dq.tail.addr
  dq.pendingTasks = 0
  # result.numSteals = 0

proc flush*[T: StealableTask](dq: var PrellDeque[T]): T {.inline.} =
  ## This returns all the StealableTasks left in the deque
  ## including the dummy node and resets the dequeue.
  if dq.pendingTasks == 0:
    ascertain: dq.head == dq.tail.addr
    return nil
  result = dq.head
  dq.tail.prev.next = nil # unlink dummy
  zeroMem(dq.addr, sizeof(dq))

# Batch routines
# ---------------------------------------------------------------

func addListFirst[T](dq: var PrellDeque[T], head, tail: sink T, len: int32) {.inline.} =
  # Add a list of tasks [head ... tail] of length len to the front of the deque
  preCondition: not head.isNil and not tail.isNil
  preCondition: len > 0
  preCondition: tail.next.isNil

  # Link tail with deque head
  tail.next = dq.head
  dq.head.prev = tail

  # Update state of the deque
  dq.head = head
  dq.pendingTasks += len

func addListFirst*[T](dq: var PrellDeque[T], head: sink T) =
  preCondition: not head.isNil

  var tail = head
  var index = 0'i32
  while not tail.next.isNil:
    tail = tail.next
    index += 1

  let len = index + 1
  dq.addListFirst(head, tail, len)

# Task-specific routines
# ---------------------------------------------------------------

func popFirstIfChild*[T](dq: var PrellDeque[T], parentTask: T): T {.inline.} =
  preCondition: not parentTask.isNil

  if dq.isEmpty():
    return nil

  result = dq.head
  if result.parent != parentTask:
    # Not a child, don't pop it
    return nil

  dq.head = dq.head.next
  dq.head.prev = nil
  result.next = nil

  dq.pendingTasks -= 1

# Work-stealing routines
# ---------------------------------------------------------------

func steal*[T](dq: var PrellDeque[T]): T =
  # Steal a task from the end of the deque
  if dq.isEmpty():
    return nil

  # Steal the true task
  result = dq.tail.prev
  result.next = nil
  # Update dummy reference to previous task
  dq.tail.prev = result.prev
  # Solen task has no predecessor anymore
  result.prev = nil

  if dq.tail.prev.isNil:
    # Stealing last task of the deque
    # ascertain: dq.head == result # Concept are buggy with repr, TODO
    dq.head = dq.tail.addr # isEmpty() condition
  else:
    dq.tail.prev.next = dq.tail.addr # last task points to dummy

  dq.pendingTasks -= 1
  # dq.numSteals += 1

template multistealImpl[T](
          dq: var PrellDeque[T],
          stolenHead: var T,
          numStolen: var int32,
          maxStmt: untyped,
          tailAssignStmt: untyped
        ): untyped =
  ## Implementation of stealing multiple tasks.
  ## All procs:
  ##   - update the numStolen param with the number of tasks stolen
  ##   - return the first task stolen (which is an intrusive linked list to the last)
  ## 4 cases:
  ##   - Steal up to N tasks
  ##   - Steal up to N tasks, also update the "tail" param
  ##   - Steal half tasks
  ##   - Steal half tasks, also update the "tail" param
  if dq.isEmpty():
    return

  # Make sure to steal at least one task
  numStolen = dq.pendingTasks shr 1 # half tasks
  if numStolen == 0: numStolen = 1
  maxStmt # <-- 1st statement "if numStolen > max: numStolen = max" injected here

  stolenHead = dq.tail.addr # dummy node

  tailAssignStmt   # <-- 2nd statement "tail = dummy.prev" injected here

  # Walk backwards from the dummy node
  for i in 0 ..< numStolen:
    stolenHead = stolenHead.prev

  dq.tail.prev.next = nil       # Detach the true tail from the dummy
  dq.tail.prev = stolenHead.prev     # Update the node the dummy points to
  stolenHead.prev = nil              # Detach the stolenHead head from the deque
  if dq.tail.prev.isNil:
    # Stealing the last task of the deque
    ascertain: dq.head == stolenHead
    dq.head = dq.tail.addr           # isEmpty() condition
  else:
    dq.tail.prev.next = dq.tail.addr # last task points to dummy

  dq.pendingTasks -= numStolen

func stealMany*[T](dq: var PrellDeque[T],
                  maxSteals: int32, # should be range[1'i32 .. high(int32)]
                  head, tail: var T,
                  numStolen: var int32) =
  ## Steal up to half of the deque's tasks, but at most maxSteals tasks
  ## head will point to the first task in the returned list
  ## tail will point to the last task in the returned list
  ## numStolen will contain the number of transferred tasks
  preCondition: maxSteals >= 1

  multistealImpl(dq, head, numStolen):
    if numStolen > maxSteals:
      numStolen = maxSteals
  do:
    tail = dq.tail.prev

func stealMany*[T](dq: var PrellDeque[T],
                  maxSteals: int32, # should be range[1'i32 .. high(int32)]
                  head: var T,
                  numStolen: var int32) =
  ## Steal up to half of the deque's tasks, but at most maxSteals tasks
  ## head will point to the first task in the returned list
  ## numStolen will contain the number of transferred tasks
  preCondition: maxSteals >= 1

  multistealImpl(dq, head, numStolen):
    if numStolen > maxSteals:
      numStolen = maxSteals
  do:
    discard

func stealHalf*[T](dq: var PrellDeque[T],
                  head, tail: var T,
                  numStolen: var int32) =
  ## Steal half of the deque's tasks (minimum one)
  ## head will point to the first task in the returned list
  ## tail will point to the last task in the returned list
  ## numStolen will contain the number of transferred tasks

  multistealImpl(dq, head, numStolen):
    discard
  do:
    tail = dq.tail.prev

func stealHalf*[T](dq: var PrellDeque[T],
                  head: var T,
                  numStolen: var int32) =
  ## Steal half of the deque's tasks (minimum one)
  ## head will point to the first task in the returned list
  ## numStolen will contain the number of transferred tasks

  multistealImpl(dq, head, numStolen):
    discard
  do:
    discard

# Unit tests
# ---------------------------------------------------------------

when isMainModule:
  import unittest, ../memory/[lookaside_lists, memory_pools, allocs]

  const
    N = 1000000 # Number of tasks to push/pop/steal
    M = 100     # Max number of tasks to steal in one swoop
    TaskDataSize = 192 - 96

  type
    Task = ptr object
      prev, next: Task
      parent: Task
      fn: proc (param: pointer) {.nimcall.}
      # User data
      data: array[TaskDataSize, byte]

    Data = object
      a, b: int32

  # Memory management
  # -------------------------------

  var pool: TLPoolAllocator

  pool.initialize()

  proc newTask(cache: var LookAsideList[Task]): Task =
    result = cache.pop()
    if result.isNil:
      result = pool.borrow(deref(Task))
    zeroMem(result, sizeof(deref(Task)))

  proc delete(task: Task) =
    recycle(task)

  iterator items(t: Task): Task =
    var cur = t
    while not cur.isNil:
      let next = cur.next
      yield cur
      cur = next

  proc recycleAll(taskList: sink Task) =
    for task in taskList:
      recycle(task)

  suite "Testing PrellDeques":
    var deq: PrellDeque[Task]
    var cache: LookAsideList[Task]
    # cache.freeFn = recycle
    # pool.hook.setHeartbeat(cache)

    test "Instantiation":
      deq.initialize()

      check:
        deq.isEmpty()
        deq.pendingTasks == 0

    test "Pushing tasks":
      for i in 0'i32 ..< N:
        let task = cache.newTask()
        check: not task.isNil

        let data = cast[ptr Data](task.data.unsafeAddr)
        data[] = Data(a: i, b: i+1)
        deq.addFirst(task)

      check:
        not deq.isEmpty()
        deq.pendingTasks == N

    test "Pop-ing tasks":
      for i in countdown(N, 1):
        let task = deq.popFirst()
        let data = cast[ptr Data](task.data.unsafeAddr)
        check:
          data.a == i-1
          data.b == i
        cache.add task

      check:
        deq.popFirst().isNil
        deq.isEmpty()
        deq.pendingTasks == 0

    test "Stealing tasks":
      for i in 0 ..< N:
        let task = cache.newTask()
        check: not task.isNil
        let data = cast[ptr Data](task.data.unsafeAddr)
        data[] = Data(a: int32 i+24, b: int32 i+42)
        deq.addFirst(task)

      check:
        # cache.isEmpty() # not exported
        not deq.isEmpty()
        deq.pendingTasks == N

      var i, numStolen = 0'i32
      while i < N:
        var head, tail: Task
        deq.stealMany(maxSteals = M, head, tail, numStolen)
        check:
          not head.isNil
          1 <= numStolen and numStolen <= M

        # "Other thread"
        var deq2: PrellDeque[Task]
        deq2.initialize()
        var cache2: LookAsideList[Task]
        cache2.freeFn = recycle

        deq2.addListFirst(head, tail, numStolen)
        check:
          not deq2.isEmpty
          deq2.pendingTasks == numStolen

        var task = deq2.popFirst()
        let
          data = cast[ptr Data](task.data.unsafeAddr)
          a = data.a
          b = data.b
        cache2.add task

        for j in 1 ..< numStolen:
          task = deq2.popFirst()
          let data = cast[ptr Data](task.data.unsafeAddr) # shadowing data
          check:
            data.a == a - j
            data.b == b - j
          cache2.add(task)

        check:
          deq2.popFirst().isNil
          deq2.steal().isNil
          deq2.isEmpty()
          deq2.pendingTasks == 0

        let leftovers = flush(deq2)
        recycleAll(leftovers)
        delete(cache2)

        # while loop increment
        i += numStolen

      check:
        deq.steal().isNil
        deq.isEmpty()
        deq.pendingTasks == 0

      let leftovers = flush(deq)
      recycleAll(leftovers)
      delete(cache)
