import
  std/atomics, std/macros,
  synthesis,
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

{.push gcsafe, raises: [].}

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
    # Channel invariant, never really empty so that producer can "exchange"
    dummy: typeof(default(T)[])
    # Consumer only
    front: T
    # back and front order is chosen so that the data structure can be
    # made intrusive to consumer data-structures
    # like the memory-pool and the events so that
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
  chan.dummy.next.store(nil, moRelaxed)
  chan.front = chan.dummy.addr
  chan.back.store(chan.dummy.addr, moRelaxed)
  when keepCount:
    chan.count.store(0, moRelaxed)

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


proc trySendImpl[T, keepCount](chan: var ChannelMpscUnboundedBatch[T, keepCount], src: sink T, dummy: static bool): bool {.inline.}=
  ## Send an item to the back of the channel
  ## As the channel has unbounded capacity, this should never fail
  when keepCount and not dummy:
    let oldCount {.used.} = chan.count.fetchAdd(1, moRelaxed)
    ascertain: oldCount >= 0

  src.next.store(nil, moRelaxed)
  fence(moRelease)
  let oldBack = chan.back.exchange(src, moRelaxed)
  # Consumer can be blocked here, it doesn't see the (potentially growing) end of the queue
  # until the next instruction.
  cast[T](oldBack).next.store(src, moRelease) # Workaround generic atomics bug: https://github.com/nim-lang/Nim/issues/12695

  return true

proc trySend[T, keepCount](chan: var ChannelMpscUnboundedBatch[T, keepCount], src: sink T): bool =
  ## Send an item to the back of the channel
  ## As the channel has unbounded capacity, this should never fail
  trySendImpl(chan, src, dummy = false)

proc reenqueueDummy(chan: var ChannelMpscUnboundedBatch) =
  discard trySendImpl(chan, chan.dummy.addr, dummy = true)

proc trySendBatch*[T, keepCount](chan: var ChannelMpscUnboundedBatch[T, keepCount], first, last: sink T, count: SomeInteger): bool {.inline.}=
  ## Send a list of items to the back of the channel
  ## They should be linked together by their next field
  ## As the channel has unbounded capacity this should never fail
  when keepCount:
    let oldCount {.used.} = chan.count.fetchAdd(int(count), moRelease)
    ascertain: oldCount >= 0

  last.next.store(nil, moRelaxed)
  fence(moRelease)
  let oldBack = chan.back.exchange(last, moRelaxed)
  # Consumer can be blocked here, it doesn't see the (potentially growing) end of the queue
  # until the next instruction.
  cast[T](oldBack).next.store(first, moRelaxed) # Workaround generic atomics bug: https://github.com/nim-lang/Nim/issues/12695

  return true

##############################################
# We implement the consumer side
# as an explicit state-machine, especially the batching
# since the dummy node makes it very tricky.
# Base algorithm is Vyukov intrusive MPSC queue
# http://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue
# which are atomics-free in the fast path,
# and only contians an atomic exchange to reenqueue the dummy node

type
  TryRecv = enum
    ## State Machine for the channel receiver
    TR_ChanEntry
    TR_HandleDummy
    TR_CheckFastPath
    TR_ExitWithNode
    TR_OneLastNodeLeft
    TR_PreFinish

  TryRecvEvent = enum
    TRE_FoundDummy
    TRE_DummyIsLastNode
    TRE_NodeIsNotLast
    TRE_ProducerAhead

declareAutomaton(tryRecvFSA, TryRecv, TryRecvEvent)
setInitialState(tryRecvFSA, TR_ChanEntry)
setTerminalState(tryRecvFSA, TR_Exit)

setPrologue(tryRecvFSA):
  ## Try receiving the next item buffered in the channel
  ## Returns true if successful (channel was not empty)
  ## This can fail spuriously on the last element if producer
  ## enqueues a new element while the consumer was dequeing it
  preCondition: not chan.front.isNil
  preCondition: not chan.back.load(moRelaxed).isNil

  var first = chan.front
  var next = cast[T](first.next.load(moRelaxed))

##############################################
# Get first node, skipping dummy if needed

implEvent(tryRecvFSA, TRE_FoundDummy):
  first == chan.dummy.addr

behavior(tryRecvFSA):
  ini: TR_ChanEntry
  event: TRE_FoundDummy
  transition: discard
  fin: TR_HandleDummy

implEvent(tryRecvFSA, TRE_DummyIsLastNode):
  next.isNil

behavior(tryRecvFSA):
  ini: TR_HandleDummy
  event: TRE_DummyIsLastNode
  transition:
    result = false
  fin: TR_Exit

behavior(tryRecvFSA):
  ini: TR_ChanEntry
  transition: discard
  fin: TR_CheckFastPath

behavior(tryRecvFSA):
  ini: TR_HandleDummy
  transition:
    # Overwrite the dummy, with the real first element
    chan.front = next
    first = next
    next = cast[T](next.next.load(moRelaxed))
  fin: TR_CheckFastPath

##############################################
# Fast-path

implEvent(tryRecvFSA, TRE_NodeIsNotLast):
  not next.isNil

behavior(tryRecvFSA):
  ini: TR_CheckFastPath
  event: TRE_NodeIsNotLast
  transition: discard
  fin: TR_ExitWithNode

behavior(tryRecvFSA):
  ini: TR_ExitWithNode
  transition:
    # second element exist, setup the queue, only consumer touches the front
    chan.front = next # switch the front
    dst = first
    when keepCount:
      let oldCount {.used.} = chan.count.fetchSub(1, moRelaxed)
      postCondition: oldCount >= 1 # The producers may overestimate the count
    result = true
  fin: TR_Exit

behavior(tryRecvFSA):
  ini: TR_CheckFastPath
  transition: discard
  fin: TR_OneLastNodeLeft

##############################################
# Front == Back
# Only one node is left, it's not the dummy
# we need to recv it and for that need to reenqueue the dummy node
# to take it's place (the channel can't be "empty")

onEntry(tryRecvFSA, TR_OneLastNodeLeft):
  let last = chan.back.load(moRelaxed)

implEvent(tryRecvFSA, TRE_ProducerAhead):
  first != last

behavior(tryRecvFSA):
  # A producer got ahead of us, spurious failure
  ini: TR_OneLastNodeLeft
  event: TRE_ProducerAhead
  transition:
    result = false
  fin: TR_Exit

behavior(tryRecvFSA):
  ini: TR_OneLastNodeLeft
  transition:
    # Reenqueue dummy, it is now in the second slot or later
    chan.reenqueueDummy()
  fin: TR_PreFinish

onEntry(tryRecvFSA, TR_PreFinish):
  # Reload the second item
  next = cast[T](first.next.load(moRelaxed))

behavior(tryRecvFSA):
  ini: TR_PreFinish
  event: TRE_NodeIsNotLast
  transition: discard
  fin: TR_ExitWithNode

behavior(tryRecvFSA):
  # No second element?! There was a race
  # in enqueueing a new dummy
  # and the new "next" still isn't published
  # spurious failure
  ini: TR_PreFinish
  transition: discard
  fin: TR_Exit

synthesize(tryRecvFSA):
  proc tryRecv*[T, keepCount](chan: var ChannelMpscUnboundedBatch[T, keepCount], dst: var T): bool

##############################################
# Batch Receive

type
  TryRecvBatch = enum
    ## State Machine for the channel receiver
    TRB_ChanEntry
    TRB_HandleDummy
    TRB_CheckFastPath
    TRB_AddNodeToBatch
    TRB_OneLastNodeLeft
    TRB_PreFinish

  TryRecvBatchEvent = enum
    TRBE_FoundDummy
    TRBE_DummyIsLastNode
    TRBE_NodeIsNotLast
    TRBE_ProducerAhead

declareAutomaton(tryRecvBatchFSA, TryRecvBatch, TryRecvBatchEvent)
setInitialState(tryRecvBatchFSA, TRB_ChanEntry)
setTerminalState(tryRecvBatchFSA, TRB_Exit)

setPrologue(tryRecvBatchFSA):
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
  ## ⚠️ This leaks the bLast.next item
  ##   nil or overwrite it for further use in linked lists
  var first: T
  var next: T

  result = 0
  bFirst = chan.front
  bLast = chan.front

setEpilogue(tryRecvBatchFSA):
  when keepCount:
    let oldCount {.used.} = chan.count.fetchSub(result, moRelaxed)
    postCondition: oldCount >= result

##############################################
# Get first node, skipping dummy if needed

onEntry(tryRecvBatchFSA, TRB_ChanEntry):
  ascertain: not chan.front.isNil
  ascertain: not chan.back.load(moRelaxed).isNil

  first = chan.front
  next = cast[T](first.next.load(moRelaxed))

implEvent(tryRecvBatchFSA, TRBE_FoundDummy):
  first == chan.dummy.addr

behavior(tryRecvBatchFSA):
  ini: TRB_ChanEntry
  event: TRBE_FoundDummy
  transition: discard
  fin: TRB_HandleDummy

implEvent(tryRecvBatchFSA, TRBE_DummyIsLastNode):
  next.isNil

behavior(tryRecvBatchFSA):
  ini: TRB_HandleDummy
  event: TRBE_DummyIsLastNode
  transition: discard
  fin: TRB_Exit

behavior(tryRecvBatchFSA):
  ini: TRB_ChanEntry
  transition: discard
  fin: TRB_CheckFastPath

behavior(tryRecvBatchFSA):
  ini: TRB_HandleDummy
  transition:
    # Overwrite the dummy, with the real first element
    if bFirst == chan.dummy.addr:
      # At first iteration we might have bFirst be the dummy
      bFirst = next
    chan.front = next
    first = next
    bLast.next.store(next, moRelaxed) # skip dummy in the created batch
    next = cast[T](next.next.load(moRelaxed))
  fin: TRB_CheckFastPath

##############################################
# Fast-path

implEvent(tryRecvBatchFSA, TRBE_NodeIsNotLast):
  not next.isNil

behavior(tryRecvBatchFSA):
  ini: TRB_CheckFastPath
  event: TRBE_NodeIsNotLast
  transition: discard
  fin: TRB_AddNodeToBatch

behavior(tryRecvBatchFSA):
  ini: TRB_AddNodeToBatch
  transition:
    # next element exist, setup the queue, only consumer touches the front
    chan.front = next  # switch the front
    bLast = first      # advance bLast
    result += 1
  fin: TRB_ChanEntry   # Repeat

behavior(tryRecvBatchFSA):
  ini: TRB_CheckFastPath
  transition: discard
  fin: TRB_OneLastNodeLeft

##############################################
# Front == Back
# Only one node is left, it's not the dummy
# we need to recv it and for that need to reenqueue the dummy node
# to take it's place (the channel can't be "empty")

onEntry(tryRecvBatchFSA, TRB_OneLastNodeLeft):
  let last = chan.back.load(moRelaxed)

implEvent(tryRecvBatchFSA, TRBE_ProducerAhead):
  first != last

behavior(tryRecvBatchFSA):
  # A producer got ahead of us, spurious failure
  ini: TRB_OneLastNodeLeft
  event: TRBE_ProducerAhead
  transition: discard
  fin: TRB_Exit

behavior(tryRecvBatchFSA):
  ini: TRB_OneLastNodeLeft
  transition:
    # Reenqueue dummy, it is now in the second slot or later
    chan.reenqueueDummy()
  fin: TRB_PreFinish

onEntry(tryRecvBatchFSA, TRB_PreFinish):
  # Reload the second item
  next = cast[T](first.next.load(moRelaxed))

behavior(tryRecvBatchFSA):
  ini: TRB_PreFinish
  event: TRBE_NodeIsNotLast
  transition: discard
  fin: TRB_AddNodeToBatch # A sudden publish might enqueue lots of nodes

behavior(tryRecvBatchFSA):
  # No next element?! There was a race
  # in enqueueing a new dummy
  # and the new "next" still isn't published
  # spurious failure
  ini: TRB_PreFinish
  transition: discard
  fin: TRB_Exit

synthesize(tryRecvBatchFSA):
  proc tryRecvBatch*[T, keepCount](chan: var ChannelMpscUnboundedBatch[T, keepCount], bFirst, bLast: var T): int32


{.pop.}
################################################################################
# Sanity checks
# ------------------------------------------------------------------------------
when isMainModule:
  import strutils, system/ansi_c, times, std/monotimes, strformat

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

      const pad = spaces(8)
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

  let startSingle = getMonoTime()
  main()
  let stopSingle = getMonoTime()
  let startBatch = getMonoTime()
  mainBatch()
  let stopBatch = getMonoTime()

  let elapsedSingle = inMilliseconds(stopSingle - startSingle)
  let throughputSingle = 15'f64 * (float64(NumVals) / float64 inMicroSeconds(stopSingle - startSingle))
  let elapsedBatch = inMilliseconds(stopBatch - startBatch)
  let throughputBatch = 15'f64 * (float64(NumVals) / float64 inMicroSeconds(stopBatch - startBatch))

  echo &"Receive single - throughput {throughputSingle:>15.3f} items/µs - elapsed {elapsedSingle:>5} ms"
  echo &"Receive batch  - throughput {throughputBatch:>15.3f} items/µs - elapsed {elapsedBatch:>5} ms"
