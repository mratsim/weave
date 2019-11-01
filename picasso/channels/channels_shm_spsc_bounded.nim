# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/atomics, std/typetraits

const CacheLineSize {.intdefine.} = 64
  ## True on most machines
  ## Notably false on Samsung phones
  ## We might need to use 2x CacheLine to avoid prefetching cache conflict

type
  ChannelShmSpscBounded*[T] = object
    ## TODO: unfinished
    ## Wait-free bounded single-producer single-consumer channel
    ## Properties:
    ##   - wait-free
    ##   - supports weak memory models
    ##   - no modulo operations
    ##   - memory-efficient: buffer the size of the capacity
    ##   - Padded to avoid false sharing
    ##   - only 2 synchronization variables.
    ##     only read-write contention (no write-write from 2 different threads)
    ##
    ## At the moment, only trivial objects can be received or sent
    ## (no GC, can be copied and no custom destructor)
    ##
    ## The content of the channel is not destroyed upon channel destruction
    ## Destroying a channel containing pointers will not deallocate them

    # TODO: Nim alignment pragma - https://github.com/nim-lang/Nim/pull/11077
    # TODO: do we create a Sender/Receiver API
    #       which would prevent misuse at compile-time?

    pad0: array[CacheLineSize, byte] # If used in a sequence of channels
    capacity: int
    buffer: ptr UncheckedArray[T]
    pad1: array[CacheLineSize - sizeof(int), byte]
    front: Atomic[int] # Range [0 -> 2*Capacity)
    # back_cache: int # TODO: cache back to avoid cache line contention
    pad2: array[CacheLineSize - sizeof(int), byte]
    back: Atomic[int] # Range [0 -> 2*Capacity)
    # front_cache: int # TODO: cache front to avoid cache line contention

    # To differentiate between full and empty case
    # we don't rollover the front and back indices to 0
    # when they reach capacity.
    # But only when they reach 2*capacity.
    # When they are the same the queue is empty.
    # When the difference is capacity, the queue is full.

  # Private aliases
  Channel[T] = ChannelShmSpscBounded[T]

proc `=`[T](
    dest: var Channel[T],
    source: Channel[T]
  ) {.error: "A channel cannot be copied".}

proc `=destroy`[T](chan: var Channel[T]) {.inline.} =
  static: assert T.supportsCopyMem # no custom destructors or ref objects
  if not chan.buffer.isNil:
    dealloc(chan.buffer)

func clear*(chan: var Channel) {.inline.} =
  ## Reinitialize the data in the channel
  ## We assume the buffer was already initialized.
  ##
  ## This is not threadsafe
  assert not chan.buffer.isNil
  chan.front.store(0, moRelaxed)
  chan.back.store(0, moRelaxed)

func initialize*[T](chan: var Channel[T], capacity: Positive) =
  ## Creates a new Shared Memory Single Producer Single Consumer Bounded channel

  # No init, we don't need to zero-mem the padding
  # `createU` is thread-local allocation.
  # No risk of false-sharing

  static: assert T.supportsCopyMem
  assert cast[ByteAddress](chan.back.addr) -
    cast[ByteAddress](chan.front.addr) >= CacheLineSize

  chan.buffer = cast[ptr UncheckedArray[T]](createU(T, capacity))
  chan.clear()

func isEmpty(chan: Channel): bool {.inline.} =
  ## Check if channel is empty
  ## ⚠ Use only in:
  ##   - the consumer thread that owns (write) to the "front" index
  ##     (dequeue / popFront)
  let front = chan.front.load(moRelaxed)
  result = front == chan.back.load(moAcquire)

func isFull(chan: Channel): bool {.inline.} =
  ## Check if channel is full
  ## ⚠ Use only in:
  ##   - the producer thread that owns (write) to the "back" index
  ##     (enqueue / pushBack)
  let back = chan.back.load(moRelaxed)
  var num_items = back - chan.front.load(moAcquire)
  result = abs(num_items) == chan.capacity

func trySend*[T](chan: var Channel[T], dst: var T): bool =
  ## Try sending the front item of the channel.
  ## Returns true if successful.
  ## Returns false if the channel was empty.
  ##
  ## ⚠ Use only in the consumer thread that reads from the channel.
  discard

func tryRecv*[T](chan: var Channel[T], src: sink T): bool =
  ## Try receiving in the back slot of the channel.
  ## Returns true if successful.
  ## Returns false if the channel was full.
  ##
  ## ⚠ Use only in the producer thread that writes into the channel.
  discard

# Sanity checks
# ------------------------------------------------------------------------------

when isMainModule:
  import
    ../memory/object_pools,
    times

  type Foo = object
    x: int

  var pool{.threadvar.}: ObjectPool[100, ChannelShmSpscBounded[Foo]]
  pool.associate()

  pool.initialize()

  proc foo() =
    let p = pool.get()
    # auto destroyed

  proc bar() =
    let p = createU(ChannelShmSpscBounded[Foo])
    dealloc(p)

  proc main() =
    const N = 10_000_000

    block: # Object Pool allocator
      let start = epochTime()
      for x in 0 ..< N:
        foo()
      let stop = epochTime()

      echo "Time elapsed for pool alloc/dealloc ", N, " channels: ", stop - start, " seconds"
      echo "Average: ", (stop - start) * 1e9 / float(N), " ns per alloc"

    block: # Nim default allocator - Note that create uses thread local heap so should be
           #                         less sensitive to thread contentions
      let start = epochTime()
      for x in 0 ..< N:
        bar()
      let stop = epochTime()

      echo "Time elapsed for Nim default alloc/dealloc ", N, " channels: ", stop - start, " seconds"
      echo "Average: ", (stop - start) * 1e9 / float(N), " ns per alloc"

    # nim c -d:release -d:danger -r -o:build/chan picasso/channels/channels_shm_spsc_bounded.nim
    #
    # Time elapsed for pool alloc/dealloc 10000000 channels: 0.08125972747802734 seconds
    # Average: 8.125972747802734 ns per alloc
    # Time elapsed for Nim default alloc/dealloc 10000000 channels: 0.4174752235412598 seconds
    # Average: 41.74752235412598 ns per alloc

  main()
