import
  std/atomics, std/macros,
  ../config,
  ../primitives/compiler_optimization_hints, # for prefetch
  ../instrumentation/[contracts, loggers]

type
  Enqueueable = concept x, type T
    x is ptr
    x.next is Atomic[pointer]
    # Workaround generic atomics bug: https://github.com/nim-lang/Nim/issues/12695

  ChannelMpscUnbounded*[T: Enqueueable] = object
    ## Lockless multi-producer single-consumer channel
    ##
    ## Properties:
    ## - Lockless
    ## - Lock-free (?): Progress guarantees to determine
    ## - Unbounded
    ## - Intrusive List based
    ## - Keep an approximate count on enqueued

    # TODO: pass this through Relacy and Valgrind/Helgrind
    #       to make sure there are no bugs
    #       on arch with relaxed memory models

    # Accessed by all
    count{.align: WV_CacheLinePadding.}: Atomic[int]
    # Producers and consumer slow-path
    back{.align: WV_CacheLinePadding.}: Atomic[pointer] # Workaround generic atomics bug: https://github.com/nim-lang/Nim/issues/12695
    dummy: typeof(default(T)[]) # Deref the pointer type
    # Consumer only
    # ⚠️ Field to be kept at the end
    #   so that it can be intrusive to consumers data structure
    #   like a memory pool
    front{.align: WV_CacheLinePadding.}: T

template checkInvariants(): untyped =
  ascertain: not(chan.front.isNil)
  ascertain: not(chan.back.load(moRelaxed).isNil)

proc initialize*[T](chan: var ChannelMpscUnbounded[T]) =
  # We keep a dummy node within the queue itself
  # it doesn't need any dynamic allocation which simplify
  # its use in an allocator
  chan.dummy.reset()
  chan.front = chan.dummy.addr
  chan.back.store(chan.dummy.addr, moRelaxed)
  chan.count.store(0, moRelaxed)

proc trySendImpl[T](chan: var ChannelMpscUnbounded[T], src: sink T, count: static bool): bool {.inline.}=
  ## Send an item to the back of the channel
  ## As the channel as unbounded capacity, this should never fail
  checkInvariants()

  when count:
    discard chan.count.fetchAdd(1, moRelaxed)
  src.next.store(nil, moRelaxed)
  fence(moRelease)
  let oldBack = chan.back.exchange(src, moRelaxed)
  cast[T](oldBack).next.store(src, moRelaxed) # Workaround generic atomics bug: https://github.com/nim-lang/Nim/issues/12695

  return true

proc trySend*[T](chan: var ChannelMpscUnbounded[T], src: sink T): bool {.inline.}=
  # log("Channel 0x%.08x trySend - front: 0x%.08x (%d), second: 0x%.08x, back: 0x%.08x\n", chan.addr, chan.front, chan.front.val, chan.front.next, chan.back)
  chan.trySendImpl(src, count = true)

proc reenqueueDummy[T](chan: var ChannelMpscUnbounded[T]) =
  # log("Channel 0x%.08x reenqueing dummy\n")
  discard chan.trySendImpl(chan.dummy.addr, count = false)

type RecvState = enum
  Entry
  SuccessfulExit
  Race
  FailedExit

proc tryRecv*[T](chan: var ChannelMpscUnbounded[T], dst: var T): bool =
  ## Try receiving the next item buffered in the channel
  ## Returns true if successful (channel was not empty)
  ## This can fail spuriously on the last element if producer
  ## enqueues a new element while the consumer was dequeing it
  checkInvariants()

  var state {.goto.} = Entry
  var first: T
    ## The item we are trying to dequeue
  var next: T
    ## The second item (after first)

  case state
  of Entry:
    first = chan.front
    next = cast[T](first.next.load(moRelaxed)) # Workaround generic atomics bug: https://github.com/nim-lang/Nim/issues/12695

    # log("Channel 0x%.08x tryRecv - first: 0x%.08x, next: 0x%.08x, last: 0x%.08x\n",
    #   chan.addr, first, next, chan.back)

    if first == chan.dummy.addr:
      # First node is the dummy
      if next.isNil:
        # Dummy has no next node
        return false
      # Overwrite the dummy, with the real first element
      chan.front = next
      first = next
      next = cast[T](next.next.load(moRelaxed))

    if not next.isNil:
      # Fast-path
      state = SuccessfulExit
    else:
      state = Race

  # End fast-path
  of SuccessfulExit:
    # second element exist, setup the queue, only consumer touches the front
    chan.front = next                     # switch the front
    prefetch(first.next.load(moRelaxed))
    # Publish the changes
    fence(moAcquire)
    dst = first
    discard chan.count.fetchSub(1, moRelaxed)
    return true

  of Race:
    # No second element, but we really need something to take
    # the place of the first, have a look on the producer side
    fence(moAcquire)
    let last = chan.back.load(moRelaxed)
    if first != last:
      # A producer got ahead of us, spurious failure
      state = FailedExit

    # Reenqueue dummy, it is now in the second slot or later
    chan.reenqueueDummy()
    # Reload the second item
    next = cast[T](first.next.load(moRelaxed))

    if not next.isNil:
      state = SuccessfulExit
    else:
      # Dummy was not published in time but it is in the queue
      discard # fall through
      # state = FailedExit

  of FailedExit:
    return false

type RecvBatchState = enum
  BatchEntry
  BatchDummy
  BatchDispatch
  Batching
  BatchRace

template checkBatchPostConditions(): untyped =
  postCondition:
    if result > 0: bLast.next.load(moRelaxed) == chan.front
    else: true
  postCondition: not chan.front.isNil

proc tryRecvBatch*[T](chan: var ChannelMpscUnbounded[T], bFirst, bLast: var T): int32 =
  ## Try receiving all items buffered in the channel
  ## Returns true if at least some items are dequeued.
  ## There might be competition with producers for the last item
  ##
  ## Items are returned as a linked list
  ## Returns the number of items received

  checkInvariants()

  var state {.goto.} = BatchEntry
  var next: T
    ## The current item evaluated
  var front: T
    ## The previous good item

  case state
  of BatchEntry:
    bFirst = chan.front
    front = chan.front
    next = cast[T](front.next.load(moRelaxed)) # Workaround generic atomics bug: https://github.com/nim-lang/Nim/issues/12695

    # fall through
  of BatchDispatch:
    if front == chan.dummy.addr:
      state = BatchDummy
    elif next == nil:
      state = BatchRace
    else:
      state = Batching

  of BatchDummy: # front == dummy, next == node after
    # We encountered a dummy node
    if next.isNil:
      # No more items, leave the dummy node at chan.front
      if result > 0:
        # If we receive some, we need to move pointers
        discard chan.count.fetchSub(result, moRelaxed)
      checkBatchPostConditions()
      postCondition: result <= 126
      return
    else:
      # More nodes after the dummy
      chan.front = next
      front = next
      next = cast[T](next.next.load(moRelaxed))
      state = BatchDispatch

  of Batching: # next == normal
    # We encountered a normal node
    chan.front = next
    fence(moAcquire)
    result += 1
    bLast = front
    front = next
    next = cast[T](front.next.load(moRelaxed))
    state = BatchDispatch

  of BatchRace: # next == nil so bLast == chan.back
    # The queue always need at least an item
    # we exit after ensuring its state

    let last = chan.back.load(moAcquire)
    if front != last:
      # A producer got head of us and the channel back moved
      checkBatchPostConditions()
      postCondition: result <= 126
      return

    chan.reenqueueDummy()
    next = cast[T](front.next.load(moRelaxed))

    if not next.isNil:
      # Advance one more
      chan.front = next
      fence(moAcquire)
      result += 1
      bLast = front
      discard chan.count.fetchSub(result, moRelaxed)
    checkBatchPostConditions()
    postCondition: result <= 126
    return

func peek*(chan: var ChannelMpscUnbounded): int32 {.inline.} =
  ## Estimates the number of items pending in the channel
  ## - If called by the consumer the true number might be more
  ##   due to producers adding items concurrently.
  ## - If called by a producer the true number is undefined
  ##   as other producers also add items concurrently and
  ##   the consumer removes them concurrently.
  ##
  ## This is a non-locking operation.
  result = int32 chan.count.load(moRelaxed)

# Sanity checks
# ------------------------------------------------------------------------------
when isMainModule:
  import strutils, system/ansi_c

  # Data structure test
  # --------------------------------------------------------

  # TODO: ensure that we don't write past the allocated buffer
  #       due to mismanagement of the front and back indices

  # Multithreading tests
  # --------------------------------------------------------
  when not compileOption("threads"):
    {.error: "This requires --threads:on compilation flag".}

  template sendLoop[T](chan: var ChannelMpscUnbounded[T],
                       data: sink T,
                       body: untyped): untyped =
    while not chan.trySend(data):
      body

  template recvLoop[T](chan: var ChannelMpscUnbounded[T],
                       data: var T,
                       body: untyped): untyped =
    while not chan.tryRecv(data):
      body

  const NumVals = 1000000
  const Padding = 10 * NumVals # Pad with a 0 so that iteration 10 of thread 3 is 3010 with 99 max iters

  type
    WorkerKind = enum
      Receiver
      Sender1
      Sender2
      Sender3
      Sender4
      Sender5
      Sender6
      Sender7
      Sender8
      Sender9
      Sender10
      Sender11
      Sender12
      Sender13
      Sender14
      Sender15

    Val = ptr ValObj
    ValObj = object
      next: Atomic[pointer]
      val: int

    ThreadArgs = object
      ID: WorkerKind
      chan: ptr ChannelMpscUnbounded[Val]

  template Worker(id: WorkerKind, body: untyped): untyped {.dirty.} =
    if args.ID == id:
      body

  template Worker(id: Slice[WorkerKind], body: untyped): untyped {.dirty.} =
    if args.ID in id:
      body

  # I think the createShared/freeShared allocators have a race condition
  proc valAlloc(): Val =
    when defined(debugNimalloc):
      createShared(ValObj)
    else:
      cast[Val](c_malloc(csize_t sizeof(ValObj)))

  proc valFree(val: Val) =
    when defined(debugNimalloc):
      freeShared(val)
    else:
      c_free(val)

  proc thread_func(args: ThreadArgs) =

    # Worker RECEIVER:
    # ---------
    # <- chan
    # <- chan
    # <- chan
    #
    # Worker SENDER:
    # ---------
    # chan <- 42
    # chan <- 53
    # chan <- 64
    Worker(Receiver):
      var counts: array[Sender1..Sender15, int]
      for j in 0 ..< 15 * NumVals:
        var val: Val
        args.chan[].recvLoop(val):
          # Busy loop, in prod we might want to yield the core/thread timeslice
          discard
        # log("Receiver got: %d at address 0x%.08x\n", val.val, val)
        let sender = WorkerKind(val.val div Padding)
        doAssert val.val == counts[sender] + ord(sender) * Padding, "Incorrect value: " & $val.val
        inc counts[sender]
        valFree(val)

    Worker(Sender1..Sender15):
      for j in 0 ..< NumVals:
        let val = valAlloc()
        val.val = ord(args.ID) * Padding + j

        # const pad = spaces(8)
        # echo pad.repeat(ord(args.ID)), 'S', $ord(args.ID), ": ", val.val

        args.chan[].sendLoop(val):
          # Busy loop, in prod we might want to yield the core/thread timeslice
          discard

  proc main() =
    echo "Testing if 15 threads can send data to 1 consumer"
    echo "------------------------------------------------------------------------"
    var threads: array[WorkerKind, Thread[ThreadArgs]]
    let chan = createSharedU(ChannelMpscUnbounded[Val]) # CreateU is not zero-init
    chan[].initialize()

    createThread(threads[Receiver], thread_func, ThreadArgs(ID: Receiver, chan: chan))
    for sender in Sender1..Sender15:
      createThread(threads[sender], thread_func, ThreadArgs(ID: sender, chan: chan))

    for worker in WorkerKind:
      joinThread(threads[worker])

    deallocShared(chan)
    echo "------------------------------------------------------------------------"
    echo "Success"

  main()
