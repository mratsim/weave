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
  chan.count.store(0, moRelaxed)
  chan.dummy.reset()
  chan.front = chan.dummy.addr
  chan.back.store(chan.dummy.addr, moRelaxed)

proc trySendImpl[T](chan: var ChannelMpscUnbounded[T], src: sink T, count: static bool): bool {.inline.}=
  ## Send an item to the back of the channel
  ## As the channel as unbounded capacity, this should never fail
  checkInvariants()

  src.next.store(nil, moRelaxed)
  fence(moRelease)
  let oldBack = chan.back.exchange(src, moRelaxed)
  cast[T](oldBack).next.store(src, moRelaxed) # Workaround generic atomics bug: https://github.com/nim-lang/Nim/issues/12695
  when count:
    discard chan.count.fetchAdd(1, moRelaxed)

  return true

proc trySend*[T](chan: var ChannelMpscUnbounded[T], src: sink T): bool =
  # log("Channel 0x%.08x trySend - front: 0x%.08x (%d), second: 0x%.08x, back: 0x%.08x\n", chan.addr, chan.front, chan.front.val, chan.front.next, chan.back)
  chan.trySendImpl(src, count = true)

proc reenqueueDummy[T](chan: var ChannelMpscUnbounded[T]) =
  # log("Channel 0x%.08x reenqueing dummy\n")
  discard chan.trySendImpl(chan.dummy.addr, count = false)

proc tryRecv*[T](chan: var ChannelMpscUnbounded[T], dst: var T): bool =
  ## Try receiving the next item buffered in the channel
  ## Returns true if successful (channel was not empty)
  ## This can fail spuriously on the last element if producer
  ## enqueues a new element while the consumer was dequeing it
  assert not(chan.front.isNil)
  assert not(chan.back.load(moRelaxed).isNil)

  var first = chan.front
  # Workaround generic atomics bug: https://github.com/nim-lang/Nim/issues/12695
  var next = cast[T](first.next.load(moRelaxed))

  # log("Channel 0x%.08x tryRecv - first: 0x%.08x (%d), next: 0x%.08x (%d), last: 0x%.08x\n",
  #   chan.addr, first, first.val, next, if not next.isNil: next.val else: 0, chan.back)

  if first == chan.dummy.addr:
    # First node is the dummy
    if next.isNil:
      # Dummy has no next node
      return false
    # Overwrite the dummy, with the real first element
    chan.front = next
    first = next
    next = cast[T](next.next.load(moRelaxed))

  # Fast-path
  if not next.isNil:
    # second element exist, setup the queue, only consumer touches the front
    chan.front = next                     # switch the front
    prefetch(first.next.load(moRelaxed))
    # Publish the changes
    fence(moAcquire)
    dst = first
    discard chan.count.fetchSub(1, moRelaxed)
    return true
  # End fast-path

  # No second element, but we really need something to take
  # the place of the first, have a look on the producer side
  fence(moAcquire)
  let last = chan.back.load(moRelaxed)
  if first != last:
    # A producer got ahead of us, spurious failure
    return false

  # Reenqueue dummy, it is now in the second slot or later
  chan.reenqueueDummy()
  # Reload the second item
  next = cast[T](first.next.load(moRelaxed))

  if not next.isNil:
    # second element exist, setup the queue, only consumer touches the front
    chan.front = next                     # switch the front
    prefetch(first.next.load(moRelaxed))
    # Publish the changes
    fence(moAcquire)
    dst = first
    discard chan.count.fetchSub(1, moRelaxed)
    return true

  # No empty element?! There was a race in enqueueing
  # and the new "next" still isn't published
  # spurious failure
  return false

func peek*(chan: var ChannelMpscUnbounded): int32 {.inline.} =
  ## Estimates the number of items pending in the channel
  ## - If called by the consumer the true number might be more
  ##   due to producers adding items concurrently.
  ## - If called by a producer the true number is undefined
  ##   as other producers also add items concurrently and
  ##   the consumer removes them concurrently.
  ##
  ## This is a non-locking operation.
  result = int32 chan.count.load(moAcquire)

  # For the consumer it's always positive or zero
  postCondition: result >= 0

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
