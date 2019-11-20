import
  std/atomics,
  ../config, # TODO: for CacheLineSize
  ../primitives/compiler_optimization_hints # for prefetch

type
  Enqueueable = concept x, type T
    x is ptr
    x.next is Atomic[T]

  ChannelMPSCunbounded*[T: Enqueueable] = object
    ## Lockless multi-producer single-consumer channel
    ##
    ## Properties:
    ## - Lockless
    ## - Lock-free (?): Progress guarantees to determine
    ## - Unbounded
    ## - Intrusive List based

    # TODO: pass this through Relacy and Valgrind/Helgrind
    #       to make sure there are no bugs
    #       on arch with relaxed memory models

    front: T
    # TODO: align
    back: Atomic[T]

proc initialize*[T](chan: var ChannelMPSCunbounded[T], dummy: T) =
  ## This queue is designed for use within a thread-safe allocator
  ## It requires an allocated dummy node for initialization
  ## but cannot rely on an allocator.
  assert not dummy.isNil
  dummy.next.store(nil, moRelaxed)
  chan.front = dummy
  chan.back.store(dummy, moRelaxed)

  assert not(chan.front.isNil)
  assert not(chan.back.load(moRelaxed).isNil)

proc trySend*[T](chan: var ChannelMPSCunbounded[T], src: sink T): bool =
  ## Send an item to the back of the channel
  ## As the channel as unbounded capacity, this should never fail
  assert not(chan.front.isNil)
  assert not(chan.back.load(moRelaxed).isNil)

  src.next.store(nil, moRelaxed)
  fence(moRelease)
  let oldBack = chan.back.exchange(src, moRelaxed)
  oldBack.next.store(src, moRelaxed)

  return true

proc tryRecv*[T](chan: var ChannelMPSCunbounded[T], dst: var T): bool =
  ## Try receiving the next item buffered in the channel
  ## Returns true if successful (channel was not empty)
  assert not(chan.front.isNil)
  assert not(chan.back.load(moRelaxed).isNil)

  let first = chan.front # dummy
  let next = first.next.load(moRelaxed)

  if not next.isNil:
    chan.front = next
    prefetch(first.next.load(moRelaxed))
    fence(moAcquire)
    dst = next
    return true

  dst = nil
  return false

# Sanity checks
# ------------------------------------------------------------------------------
when isMainModule:
  import strutils

  # Data structure test
  # --------------------------------------------------------

  # TODO: ensure that we don't write past the allocated buffer
  #       due to mismanagement of the front and back indices

  # Multithreading tests
  # --------------------------------------------------------
  when not compileOption("threads"):
    {.error: "This requires --threads:on compilation flag".}

  template sendLoop[T](chan: var ChannelMPSCunbounded[T],
                       data: sink T,
                       body: untyped): untyped =
    while not chan.trySend(data):
      body

  template recvLoop[T](chan: var ChannelMPSCunbounded[T],
                       data: var T,
                       body: untyped): untyped =
    while not chan.tryRecv(data):
      body

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
      next: Atomic[Val]
      val: int

    ThreadArgs = object
      ID: WorkerKind
      chan: ptr ChannelMPSCunbounded[Val]

  template Worker(id: WorkerKind, body: untyped): untyped {.dirty.} =
    if args.ID == id:
      body

  template Worker(id: Slice[WorkerKind], body: untyped): untyped {.dirty.} =
    if args.ID in id:
      body

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
      for j in 0 ..< 150:
        var val: Val
        args.chan[].recvLoop(val):
          # Busy loop, in prod we might want to yield the core/thread timeslice
          discard
        echo "Receiver got: ", val.val, " at address 0x", toLowerASCII toHex cast[ByteAddress](val)
        let sender = WorkerKind(val.val div 100)
        doAssert val.val == counts[sender] + ord(sender) * 100, "Incorrect value: " & $val.val
        inc counts[sender]
        freeShared(val)

    Worker(Sender1..Sender15):
      for j in 0 ..< 10:
        let val = createShared(ValObj)
        val.val = ord(args.ID) * 100 + j
        args.chan[].sendLoop(val):
          # Busy loop, in prod we might want to yield the core/thread timeslice
          discard

        const pad = spaces(8)
        echo pad.repeat(ord(args.ID)), 'S', $ord(args.ID), ": ", val.val

  proc main() =
    echo "Testing if 15 threads can send data to 1 consumer"
    echo "------------------------------------------------------------------------"
    var threads: array[WorkerKind, Thread[ThreadArgs]]
    let chan = createSharedU(ChannelMPSCunbounded[Val]) # CreateU is not zero-init
    let dummy = createShared(ValObj)
    chan[].initialize(dummy)

    createThread(threads[Receiver], thread_func, ThreadArgs(ID: Receiver, chan: chan))
    for sender in Sender1..Sender15:
      createThread(threads[sender], thread_func, ThreadArgs(ID: sender, chan: chan))

    for worker in WorkerKind:
      joinThread(threads[worker])

    deallocShared(dummy)
    deallocShared(chan)
    echo "------------------------------------------------------------------------"
    echo "Success"

  main()
