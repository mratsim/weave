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

  ChannelMpscUnboundedBatch*[T: Enqueueable] = object
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
    # Consumer only - front is a dummy node
    front{.align: WV_CacheLinePadding.}: typeof(default(T)[])

proc initialize*[T](chan: var ChannelMpscUnboundedBatch[T]) {.inline.}=
  chan.front.next.store(nil, moRelaxed)
  chan.back.store(chan.front.addr, moRelaxed)
  chan.count.store(0, moRelaxed)

proc trySend*[T](chan: var ChannelMpscUnboundedBatch[T], src: sink T): bool {.inline.}=
  ## Send an item to the back of the channel
  ## As the channel as unbounded capacity, this should never fail

  debug: log("Channel MPSC 0x%.08x: sending       0x%.08x\n", chan.addr, src)

  discard chan.count.fetchAdd(1, moRelaxed)
  src.next.store(nil, moRelaxed)
  fence(moRelease)
  let oldBack = chan.back.exchange(src, moRelaxed)
  cast[T](oldBack).next.store(src, moRelaxed) # Workaround generic atomics bug: https://github.com/nim-lang/Nim/issues/12695

  return true

proc tryRecv*[T](chan: var ChannelMpscUnboundedBatch[T], dst: var T): bool =
  ## Try receiving the next item buffered in the channel
  ## Returns true if successful (channel was not empty)
  ## This can fail spuriously on the last element if producer
  ## enqueues a new element while the consumer was dequeing it

  # log("Channel 0x%.08x tryRecv - first: 0x%.08x (%d), next: 0x%.08x (%d), last: 0x%.08x\n",
  #   chan.addr, first, first.val, next, if not next.isNil: next.val else: 0, chan.back)

  let first = cast[T](chan.front.next.load(moRelaxed))
  if first.isNil:
    return false
  debug: log("Channel MPSC 0x%.08x: try receiving 0x%.08x\n", chan.addr, first)

  block fastPath:
    let next = first.next.load(moRelaxed)
    if not next.isNil:
      # Not competing with producers
      discard chan.count.fetchSub(1, moRelaxed)
      chan.front.next.store(next, moRelaxed)
      prefetch(first)
      # Prevent reordering
      fence(moAcquire)
      dst = first
      return true

  # Competing with producers at the back
  var last = chan.back.load(moRelaxed)
  if first != last:
    # We lose the competition before even trying
    return false

  chan.front.next.store(nil, moRelaxed)
  if compareExchange(chan.back, last, chan.front.addr, moAcquireRelease):
    # We won and replaced the last node with the channel front
    discard chan.count.fetchSub(1, moRelaxed)
    dst = first
    return true

  # We lost again but now we know that there is an extra node
  cpuRelax() # Would be nice to not need this but it seems like
  cpuRelax() # fibonacci or the memory pool test thrashes or livelock
             # if consumer doesn't backoff
  let next2 = first.next.load(moRelaxed)
  if not next2.isNil:
    discard chan.count.fetchSub(1, moRelaxed)
    chan.front.next.store(next2, moRelaxed)
    prefetch(first)
    # Prevent reordering
    fence(moAcquire)
    dst = first
    return true

  # We lost again
  return false

func peek*(chan: var ChannelMpscUnboundedBatch): int32 {.inline.} =
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
  postCondition: result >= 0 # TODO somehow it can be -1

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

  template sendLoop[T](chan: var ChannelMpscUnboundedBatch[T],
                       data: sink T,
                       body: untyped): untyped =
    while not chan.trySend(data):
      body

  template recvLoop[T](chan: var ChannelMpscUnboundedBatch[T],
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
      chan: ptr ChannelMpscUnboundedBatch[Val]

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

      for count in counts:
        doAssert count == NumVals

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
    let chan = createSharedU(ChannelMpscUnboundedBatch[Val]) # CreateU is not zero-init
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
