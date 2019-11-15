# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  locks, atomics, typetraits,
  ../config,
  ../instrumentation/contracts,
  ../memory/allocs

type
  ChannelMpscBounded*[T] = object
    ## Lock-based multi-producer single-consumer channel
    ##
    ## Properties:
    ##   - Lock-based for the producers
    ##   - lock-free for the consumer
    ##   - no modulo operations
    ##   - memory-efficient: buffer the size of the capacity
    ##   - Padded to avoid false sharing
    ##   - Linearizable
    ##
    ## Usage:
    ##   - When producer wait/sleep is not an issue as they don't have
    ##     useful work to do.
    ##   - Must be heap allocated
    ##   - Only trivial objects can transit (no GC, can be copied and no custom destructor)
    ##   - The content of the channel is not destroyed upon channel destruction
    ##     Deleting a channel containing ptr object will not deallocate them
    ##
    ## Peeking into a MPSC channel gives an approximation of the number of items
    ## buffered, it is at best an estimate. An exact result would require locking
    ## and may be invalid the nanosecond after you release the lock.
    ##
    ## Semantics:
    ##
    ## The channel is a synchronization point,
    ## the sender should be ensured that data is read only once and ownership is transferred
    ## and the receiver should be ensured that a duplicate isn't left on the sender side.
    ## As such, sending is "sinked" and receiving will always remove data from the channel.
    ##
    ## So this channel provides message passing
    ## with the following strong guarantees:
    ## - Messages are guaranteed to be delivered
    ## - Messages will be delivered exactly once
    ## - Linearizability
    pad0: array[PI_CacheLineSize - 3*sizeof(int32), byte]
    backLock: Lock # Padding? - pthread_lock is 40 bytes on Linux, unknown on windows.
    capacity: int32
    buffer: ptr UncheckedArray[T]
    pad1: array[PI_CacheLineSize - sizeof(int32), byte]
    front: Atomic[int32]
    pad2: array[PI_CacheLineSize - sizeof(int32), byte]
    back: Atomic[int32]

  # Private aliases
  Channel[T] = ChannelMpscBounded[T]

proc `=`[T](
    dest: var Channel[T],
    source: Channel[T]
  ) {.error: "A channel cannot be copied".}

proc delete*[T](chan: var Channel[T]) {.inline.} =
  static:
    # Steal request cannot be copied and so
    # don't "support copyMem"
    # assert T.supportsCopyMem
    discard

  if not chan.buffer.isNil:
    pi_free(chan.buffer)

func clear*(chan: var ChannelMpscBounded) {.inline.} =
  ## Reinitialize the data in the channel
  ## We assume the buffer was already initialized.
  ##
  ## This is not threadsafe
  preCondition(not chan.buffer.isNil)

  chan.front.store(0, moRelaxed)
  chan.back.store(0, moRelaxed)

proc initialize*[T](chan: var ChannelMpscBounded[T], capacity: int32) {.inline.} =
  ## Creates a new Shared Memory Multi-Producer Producer Single Consumer Bounded channel
  ## Channels should be allocated on the shared memory heap
  ##
  ## When using multiple channels it is recommended that
  ## you use a pointer to an array of channels
  ## instead of an array of pointer to channels.
  ##
  ## This will limit memory fragmentation and also reduce the number
  ## of potential cache and TLB misses
  ##
  ## Channels are padded to avoid false-sharing when packed
  ## in arrays.

  # We don't need to zero-mem the padding
  static:
    # Steal request cannot be copied and so
    # don't "support copyMem"
    # assert T.supportsCopyMem
    discard

  chan.capacity = capacity
  chan.buffer = pi_alloc(T, capacity)
  chan.clear()

# To differentiate between full and empty case
# we don't rollover the front and back indices to 0
# when they reach capacity.
# But only when they reach 2*capacity.
# When they are the same the queue is empty.
# When the difference is capacity, the queue is full.

func isFull(chan: var Channel, back: var int32): bool {.inline.} =
  ## Check if channel is full
  ## Update the back index value with its atomically read value
  ##
  ## ⚠ Use only in:
  ##   - a producer thread that writes to the "back" index
  ##     (send / enqueue / pushBack)
  back = chan.back.load(moRelaxed)
  let num_items = back - chan.front.load(moAcquire)
  result = abs(num_items) == chan.capacity

template isFull(chan: var Channel): bool =
  ## Check if channel is full
  ## ⚠ Use only in:
  ##   - a producer thread that writes to the "back" index
  ##     (send / enqueue / pushBack)
  var back: int32
  isFull(chan, back)

func trySend*[T](chan: var ChannelMpscBounded[T], src: sink T): bool =
  ## Try sending in the back slot of the channel
  ## Returns true if successful
  ## Returns false if the channel was full
  ##
  ## ⚠ Use only in the producer threads that write into the channel.
  ## ⚠ This is a blocking operation, in case 2 producers try to send a message
  ##    one will be put to sleep.
  if chan.isFull():
    return false

  acquire(chan.backLock)
  var back: int32

  # Check again if full, if not cache the atomically read back index
  # - front: moAcquire
  # - back: moRelaxed
  if chan.isFull(back):
    # Another thread was faster
    release(chan.backLock)
    return false

  let writeIdx = if back < chan.capacity: back
                 else: back - chan.capacity
  `=sink`(chan.buffer[writeIdx], src)

  var nextWrite = back + 1
  if nextWrite == 2 * chan.capacity:
    nextWrite = 0
  chan.back.store(nextWrite, moRelease)

  release(chan.backLock)
  return true

func tryRecv*[T](chan: var ChannelMpscBounded[T], dst: var T): bool =
  ## Try receiving the next item buffered in the channel
  ## Returns true if successful (channel was not empty)
  ##
  ## ⚠ Use only in the consumer thread that reads from the channel.
  let front = chan.front.load(moRelaxed)
  if front == chan.back.load(moAcquire):
    # Empty
    return false

  let readIdx = if front < chan.capacity: front
                else: front - chan.capacity
  `=sink`(dst, chan.buffer[readIdx])

  var nextRead = front + 1
  if nextRead == 2 * chan.capacity:
    nextRead = 0
  chan.front.store(nextRead, moRelease)
  return true

func peek*(chan: var ChannelMpscBounded): int32 {.inline.} =
  ## Estimates the number of items pending in the channel
  ## - If called by the consumer the true number might be more
  ##   due to producers adding items concurrently.
  ## - If called by a producer the true number is undefined
  ##   as other producers also add items concurrently and
  ##   the consumer removes them concurrently.
  ##
  ## This is a non-locking operation.
  result = chan.front.load(moAcquire) - chan.back.load(moAcquire)
  if result < 0:
    result += 2 * chan.capacity

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

  template sendLoop[T](chan: var Channel[T],
                       data: sink T,
                       body: untyped): untyped =
    while not chan.trySend(data):
      body

  template recvLoop[T](chan: var Channel[T],
                       data: var T,
                       body: untyped): untyped =
    while not chan.tryRecv(data):
      body

  type
    ThreadArgs = object
      ID: WorkerKind
      chan: ptr Channel[int]

    WorkerKind = enum
      Receiver
      Sender1
      Sender2
      Sender3

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
      var val: int
      var counts: array[Sender1..Sender3, int]
      for j in 0 ..< 30:
        args.chan[].recvLoop(val):
          # Busy loop, in prod we might want to yield the core/thread timeslice
          discard
        echo "Receiver got: ", val
        let sender = WorkerKind(val div 10)
        doAssert val == counts[sender] + ord(sender) * 10, "Incorrect value: " & $val
        inc counts[sender]

    Worker(Sender1..Sender3):
      doAssert args.chan[].isFull() == false
      for j in 0 ..< 10:
        let val = ord(args.ID) * 10 + j
        args.chan[].sendLoop(val):
          # Busy loop, in prod we might want to yield the core/thread timeslice
          discard

        const pad = spaces(18)
        echo pad.repeat(ord(args.ID)), $args.ID, " sent: ", val

  proc main(capacity: int32) =
    echo "Testing if 3 threads can send data to 1 consumer - channel capacity: ", capacity
    echo "------------------------------------------------------------------------"
    var threads: array[4, Thread[ThreadArgs]]
    let chan = createU(Channel[int]) # CreateU is not zero-init
    chan[].initialize(capacity)

    createThread(threads[0], thread_func, ThreadArgs(ID: Receiver, chan: chan))
    createThread(threads[1], thread_func, ThreadArgs(ID: Sender1, chan: chan))
    createThread(threads[2], thread_func, ThreadArgs(ID: Sender2, chan: chan))
    createThread(threads[3], thread_func, ThreadArgs(ID: Sender3, chan: chan))

    joinThread(threads[0])
    joinThread(threads[1])
    joinThread(threads[2])
    joinThread(threads[3])

    dealloc(chan)
    echo "------------------------------------------------------------------------"
    echo "Success"

  main(2)
  main(10)
