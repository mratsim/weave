import
  std/atomics, std/macros,
  ../config,
  ../primitives/compiler_optimization_hints, # for prefetch
  ../instrumentation/[contracts, loggers]

# type dereference macro
# ------------------------------------------------
# This macro dereference pointer types
# This workarounds:
# - https://github.com/nim-lang/Nim/issues/12714
# - https://github.com/nim-lang/Nim/issues/13048

# MPSC channel
# ------------------------------------------------

const MpscPadding = WV_CacheLinePadding div 2
  ## The padding is chosen so that:
  ## - The data structure fits in WV_MemBlockSize (4x cache-line by default)
  ## - The front and back fields which are respectively owned by consumer and the producers
  ##   accessed only by the consumer for the first and mostly by producers for the second
  ##   are kept 1 cache-line apart.
  ## - We keep 1 cache-line apart instead of 2 to save on size
  ## - The count field is kept in the same cache-line as the back field
  ##   to save on size and as they have the same contention profile.

type
  Enqueueable = concept x, type T
    x is ptr
    x.next is Atomic[pointer]
    # Workaround generic atomics bug: https://github.com/nim-lang/Nim/issues/12695

  ChannelMpscUnboundedBatch*[T: Enqueueable, keepCount: static bool] = object
    ## Lockless multi-producer single-consumer channel
    ##
    ## Properties:
    ## - Lockless
    ## - Wait-free for producers
    ## - Consumer can be blocked by producers when they swap
    ##   the tail, the tail can grow but the consumer sees it as nil
    ##   until it's published all at once.
    ## - Unbounded
    ## - Intrusive List based
    ## - Keep an approximate count on enqueued
    ## - Support batching on both the producers and consumer side

    # TODO: pass this through Relacy and Valgrind/Helgrind
    #       to make sure there are no bugs
    #       on arch with relaxed memory models

    # Producers and consumer slow-path
    back{.align: MpscPadding.}: Atomic[pointer] # Workaround generic atomics bug: https://github.com/nim-lang/Nim/issues/12695
    # Accessed by all
    count: Atomic[int]
    # Consumer only - front is a dummy node
    front{.align: MpscPadding.}: typeof(default(T)[])
    # back and front order is chosen so that the data structure can be
    # made intrusive to consumer data-structures
    # like the memory-pool and the pledges so that
    # producer accesses don't invalidate consumer cache-lines
    #
    # The padding is a compromise to keep back and front 1 cache line apart
    # but still have a reasonable MPSC Channel size of 2xCacheLine (instead of 3x)

# Debugging
# --------------------------------------------------------------

# Insert the following lines in the relevant places

# Send:
# debug: log("Channel MPSC 0x%.08x: sending       0x%.08x\n", chan.addr, src)

# Recv:
# debug: log("Channel MPSC 0x%.08x: try receiving 0x%.08x\n", chan.addr, first)

# Implementation
# --------------------------------------------------------------

proc initialize*[T, keepCount](chan: var ChannelMpscUnboundedBatch[T, keepCount]) {.inline.}=
  chan.front.next.store(nil, moRelaxed)
  chan.back.store(chan.front.addr, moRelaxed)
  when keepCount:
    chan.count.store(0, moRelaxed)

proc trySend*[T, keepCount](chan: var ChannelMpscUnboundedBatch[T, keepCount], src: sink T): bool {.inline.}=
  ## Send an item to the back of the channel
  ## As the channel has unbounded capacity, this should never fail

  when keepCount:
    let oldCount {.used.} = chan.count.fetchAdd(1, moRelease)
    ascertain: oldCount >= 0

  src.next.store(nil, moRelease)
  let oldBack = chan.back.exchange(src, moAcquireRelease)
  # Consumer can be blocked here, it doesn't see the (potentially growing) end of the queue
  # until the next instruction.
  cast[T](oldBack).next.store(src, moRelease) # Workaround generic atomics bug: https://github.com/nim-lang/Nim/issues/12695

  return true

proc trySendBatch*[T, keepCount](chan: var ChannelMpscUnboundedBatch[T, keepCount], first, last: sink T, count: SomeInteger): bool {.inline.}=
  ## Send a list of items to the back of the channel
  ## They should be linked together by their next field
  ## As the channel has unbounded capacity this should never fail

  when keepCount:
    let oldCount {.used.} = chan.count.fetchAdd(int(count), moRelease)
    ascertain: oldCount >= 0

  last.next.store(nil, moRelease)
  let oldBack = chan.back.exchange(last, moAcquireRelease)
  # Consumer can be blocked here, it doesn't see the (potentially growing) end of the queue
  # until the next instruction.
  cast[T](oldBack).next.store(first, moRelease) # Workaround generic atomics bug: https://github.com/nim-lang/Nim/issues/12695

  return true

proc tryRecv*[T, keepCount](chan: var ChannelMpscUnboundedBatch[T, keepCount], dst: var T): bool =
  ## Try receiving the next item buffered in the channel
  ## Returns true if successful (channel was not empty)
  ## This can fail spuriously on the last element if producer
  ## enqueues a new element while the consumer was dequeing it

  let first = cast[T](chan.front.next.load(moAcquire))
  if first.isNil:
    # According to the model checker, we can't put "fence(moAcquire)"
    # here and use relaxed semantics for "first" as it may read from initialized load
    # (due to compiler reordering?)
    return false

  # fast path
  block:
    let next = first.next.load(moAcquire)
    if not next.isNil:
      # Not competing with producers
      prefetch(first)

      chan.front.next.store(next, moRelaxed)
      # fence(moAcquire) # Sync "first.next.load(moRelaxed)"
      dst = first

      when keepCount:
        let oldCount {.used.} = chan.count.fetchSub(1, moRelaxed)
        postCondition: oldCount >= 1 # The producers may overestimate the count
      return true
  # End fast-path

  # Competing with producers at the back
  var last = chan.back.load(moAcquire)
  if first != last:
    # We lose the competition before even trying
    # fence(moAcquire) # Sync "chan.back.load(moRelaxed)"
    return false

  chan.front.next.store(nil, moAcquire)
  if compareExchange(chan.back, last, chan.front.addr, moAcquireRelease):
    # We won and replaced the last node with the channel front
    prefetch(first)
    dst = first

    when keepCount:
      let oldCount {.used.} = chan.count.fetchSub(1, moRelaxed)
      postCondition: oldCount >= 1 # The producers may overestimate the count
    return true

  # We lost but now we know that there is an extra node coming very soon
  var next = first.next.load(moAcquire)
  while next.isNil:
    # We spinlock, unfortunately there seems to be a livelock potential
    # or contention issue if we don't use cpuRelax
    # at least twice or just bail out if next is nil.
    # Replace this spinlock by "if not next.isNil" and run the "memory pool" bench
    # or fibonacci and the program will get stuck.
    # The queue should probably be model checked and/or run through Relacy
    cpuRelax()
    next = first.next.load(moAcquire)

  prefetch(first)
  chan.front.next.store(next, moRelaxed)
  # fence(moAcquire) # sync first.next.load(moRelaxed)
  dst = first

  when keepCount:
    let oldCount {.used.} = chan.count.fetchSub(1, moRelaxed)
    postCondition: oldCount >= 1 # The producers may overestimate the count
  return true

  # # Alternative implementation
  # #
  # # We lost but now we know that there is an extra node coming very soon
  # cpuRelax()
  # let next = first.next.load(moAcquire)
  # if not next.isNil:
  #   # Extra nodes after this one, no more competition with producers
  #   prefetch(first)
  #   discard chan.count.fetchSub(1, moRelaxed)
  #   chan.front.next.store(next, moRelease)
  #   dst = first
  #   return true

  # # The last item wasn't linked to the list yet, bail out
  # return false

proc tryRecvBatch*[T, keepCount](chan: var ChannelMpscUnboundedBatch[T, keepCount], bFirst, bLast: var T): int32 =
  ## Try receiving all items buffered in the channel
  ## Returns true if at least some items are dequeued.
  ## There might be competition with producers for the last item
  ##
  ## Items are returned as a linked list
  ## Returns the number of items received
  ##
  ## If no items are returned bFirst and bLast are undefined
  ## and should not be used.
  ##
  ## ⚠️ This leaks the next item
  ##   nil or overwrite it for further use in linked lists

  result = 0

  var front = cast[T](chan.front.next.load(moAcquire))
  bFirst = front
  if front.isNil:
    return

  # Fast-forward to the end of the channel
  var next = cast[T](front.next.load(moAcquire))
  while not next.isNil:
    result += 1
    bLast = front
    front = next
    next = cast[T](next.next.load(moAcquire))

  # Competing with producers at the back
  var last = chan.back.load(moAcquire)
  if front != last:
    # We lose the competition, bail out
    chan.front.next.store(front, moRelease)

    when keepCount:
      let oldCount {.used.} = chan.count.fetchSub(result, moRelaxed)
      postCondition: oldCount >= result # TODO: somehow it can be negative
    return

  # front == last
  chan.front.next.store(nil, moRelaxed)
  if compareExchange(chan.back, last, chan.front.addr, moAcquireRelease):
    # We won and replaced the last node with the channel front
    prefetch(front)
    result += 1
    bLast = front

    when keepCount:
      let oldCount {.used.} = chan.count.fetchSub(result, moRelaxed)
      postCondition: oldCount >= result # TODO: somehow it can be negative
    return

  # We lost but now we know that there is an extra node
  # We don't spinlock unlike the single receive case
  # we assume that consumer has plenty of work to do with the
  # already retrived batch
  next = cast[T](front.next.load(moAcquire))
  while next.isNil:
    # We spinlock, unfortunately there seems to be a livelock potential
    # or contention issue if we don't use cpuRelax
    # at least twice or just bail out if next is nil.
    # Replace this spinlock by "if not next.isNil" and run the "memory pool" bench
    # or fibonacci and the program will get stuck.
    # The queue should probably be model checked and/or run through Relacy
    cpuRelax()
    next = cast[T](front.next.load(moAcquire))

  prefetch(front)
  result += 1
  chan.front.next.store(next, moRelaxed)
  # fence(moAcquire)  # sync front.next.load(moRelaxed)
  bLast = front

  when keepCount:
    let oldCount {.used.} = chan.count.fetchSub(result, moRelaxed)
    postCondition: oldCount >= result # TODO: somehow it can be negative

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
  import strutils, system/ansi_c, times

  # Data structure test
  # --------------------------------------------------------

  # TODO: ensure that we don't write past the allocated buffer
  #       due to mismanagement of the front and back indices

  # Multithreading tests
  # --------------------------------------------------------
  when not compileOption("threads"):
    {.error: "This requires --threads:on compilation flag".}

  template sendLoop[T, keepCount](chan: var ChannelMpscUnboundedBatch[T, keepCount],
                       data: sink T,
                       body: untyped): untyped =
    while not chan.trySend(data):
      body

  template recvLoop[T, keepCount](chan: var ChannelMpscUnboundedBatch[T, keepCount],
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
      chan: ptr ChannelMpscUnboundedBatch[Val, true]

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

  proc thread_func_sender(args: ThreadArgs) =
    for j in 0 ..< NumVals:
      let val = valAlloc()
      val.val = ord(args.ID) * Padding + j

      # const pad = spaces(8)
      # echo pad.repeat(ord(args.ID)), 'S', $ord(args.ID), ": ", val.val, " (0x", toHex(cast[uint32](val)), ')'

      args.chan[].sendLoop(val):
        # Busy loop, in prod we might want to yield the core/thread timeslice
        discard

  proc thread_func_receiver(args: ThreadArgs) =
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

  proc main() =
    echo "Testing if 15 threads can send data to 1 consumer"
    echo "------------------------------------------------------------------------"
    var threads: array[WorkerKind, Thread[ThreadArgs]]
    let chan = createSharedU(ChannelMpscUnboundedBatch[Val, true]) # CreateU is not zero-init
    chan[].initialize()

    createThread(threads[Receiver], thread_func_receiver, ThreadArgs(ID: Receiver, chan: chan))
    for sender in Sender1..Sender15:
      createThread(threads[sender], thread_func_sender, ThreadArgs(ID: sender, chan: chan))

    for worker in WorkerKind:
      joinThread(threads[worker])

    deallocShared(chan)
    echo "------------------------------------------------------------------------"
    echo "Success"

  proc thread_func_receiver_batch(args: ThreadArgs) =
    var counts: array[Sender1..Sender15, int]
    var received = 0
    var batchID = 0
    while received < 15 * NumVals:
      var first, last: Val
      let batchSize = args.chan[].tryRecvBatch(first, last)
      batchID += 1
      if batchSize == 0:
        continue

      var cur = first
      var idx = 0
      while idx < batchSize:
        # log("Receiver got: %d at address 0x%.08x\n", cur.val, cur)
        let sender = WorkerKind(cur.val div Padding)
        doAssert cur.val == counts[sender] + ord(sender) * Padding, "Incorrect value: " & $cur.val
        counts[sender] += 1
        received += 1

        idx += 1
        if idx == batchSize:
          doAssert cur == last

        let old = cur
        cur = cast[Val](cur.next.load(moRelaxed))
        valFree(old)
      # log("Receiver processed batch id %d of size %d (received total %d) \n", batchID, batchSize, received)

    doAssert received == 15 * NumVals, "Received more than expected"
    for count in counts:
      doAssert count == NumVals

  proc mainBatch() =
    echo "Testing if 15 threads can send data to 1 consumer with batch receive"
    echo "------------------------------------------------------------------------"
    var threads: array[WorkerKind, Thread[ThreadArgs]]
    let chan = createSharedU(ChannelMpscUnboundedBatch[Val, true]) # CreateU is not zero-init
    chan[].initialize()

    # log("Channel address 0x%.08x (dummy 0x%.08x)\n", chan, chan.front.addr)

    createThread(threads[Receiver], thread_func_receiver_batch, ThreadArgs(ID: Receiver, chan: chan))
    for sender in Sender1..Sender15:
      createThread(threads[sender], thread_func_sender, ThreadArgs(ID: sender, chan: chan))

    for worker in WorkerKind:
      joinThread(threads[worker])

    deallocShared(chan)
    echo "------------------------------------------------------------------------"
    echo "Success"

  let startSingle = epochTime()
  main()
  let stopSingle = epochTime()
  let startBatch = epochTime()
  mainBatch()
  let stopBatch = epochTime()

  echo "Receive single time elapsed: ", stopSingle-startSingle, " seconds"
  echo "Receive batch time elapsed: ", stopBatch-startBatch, " seconds"
