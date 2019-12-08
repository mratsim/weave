# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/atomics,
  ../config,
  ../instrumentation/[contracts, loggers],
  ../memory/memory_pools

type
  ChannelSPSCSingle* = object
    ## A type-erased SPSC channel.
    ##
    ## Wait-free bounded single-producer single-consumer channel
    ## that can only buffer a single item
    ## Properties:
    ##   - wait-free
    ##   - supports weak memory models
    ##   - buffers a single item
    ##   - Padded to avoid false sharing in collections
    ##   - No extra indirection to access the item, the buffer is inline the channel
    ##   - Linearizable
    ##   - Default usable size is 254 bytes (WV_MemBlockSize - 2).
    ##     If used in an intrusive manner, it's 126 bytes due to the default 128 bytes padding.
    ##
    ## The channel should be the last field of an object if used in an intrusive manner
    ##
    ## Motivations for type erasure
    ## - when LazyFlowvar needs to be converted
    ##   from stack-allocated memory to heap to extended their lifetime
    ##   we have no type information at all as the whole runtime
    ##   and especially tasks does not retain it.
    ##
    ## - When a task depends on a future that was generated from lazy loop-splitting
    ##   we don't have type information either.
    ##
    ## - An extra benefit is probably easier embedding, or calling
    ##   from C or JIT code.
    full{.align: WV_CacheLinePadding.}: Atomic[bool]
    itemSize*: uint8
    buffer*{.align: 8.}: UncheckedArray[byte]

proc `=`(
    dest: var ChannelSPSCSingle,
    source: ChannelSPSCSingle
  ) {.error: "A channel cannot be copied".}

proc initialize*(chan: var ChannelSPSCSingle, itemsize: SomeInteger) {.inline.} =
  ## If ChannelSPSCSingle is used intrusive another data structure
  ## be aware that it should be the last part due to ending by UncheckedArray
  ## Also due to 128 bytes padding, it automatically takes half
  ## of the default WV_MemBlockSize
  preCondition: itemsize.int in 0 .. int high(uint8)
  preCondition: itemSize.int +
                sizeof(chan.itemsize) +
                sizeof(chan.full) < WV_MemBlockSize

  chan.itemSize = uint8 itemsize
  chan.full.store(false, moRelaxed)

func isEmpty*(chan: var ChannelSPSCSingle): bool {.inline.} =
  not chan.full.load(moAcquire)

func tryRecv*[T](chan: var ChannelSPSCSingle, dst: var T): bool {.inline.} =
  ## Try receiving the item buffered in the channel
  ## Returns true if successful (channel was not empty)
  ##
  ## ⚠ Use only in the consumer thread that reads from the channel.
  preCondition: sizeof(T) == chan.itemsize.int

  let full = chan.full.load(moAcquire)
  if not full:
    return false
  copyMem(dst.addr, chan.buffer.addr, chan.itemsize)
  chan.full.store(false, moRelease)
  return true

func trySend*[T](chan: var ChannelSPSCSingle, src: sink T): bool {.inline.} =
  ## Try sending an item into the channel
  ## Reurns true if successful (channel was empty)
  ##
  ## ⚠ Use only in the producer thread that writes from the channel.
  preCondition: sizeof(T) == chan.itemsize.int

  let full = chan.full.load(moAcquire)
  if full:
    return false
  copyMem(chan.buffer.addr, src.addr, chan.itemsize)
  chan.full.store(true, moRelease)
  return true

# Sanity checks
# ------------------------------------------------------------------------------
when isMainModule:

  when not compileOption("threads"):
    {.error: "This requires --threads:on compilation flag".}

  template sendLoop[T](chan: var ChannelSPSCSingle,
                       data: sink T,
                       body: untyped): untyped =
    while not chan.trySend(data):
      body

  template recvLoop[T](chan: var ChannelSPSCSingle,
                       data: var T,
                       body: untyped): untyped =
    while not chan.tryRecv(data):
      body

  type
    ThreadArgs = object
      ID: WorkerKind
      chan: ptr ChannelSPSCSingle

    WorkerKind = enum
      Sender
      Receiver

  template Worker(id: WorkerKind, body: untyped): untyped {.dirty.} =
    if args.ID == id:
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
      for j in 0 ..< 10:
        args.chan[].recvLoop(val):
          # Busy loop, in prod we might want to yield the core/thread timeslice
          discard
        echo "                  Receiver got: ", val
        doAssert val == 42 + j*11

    Worker(Sender):
      doAssert args.chan.full.load(moRelaxed) == false
      for j in 0 ..< 10:
        let val = 42 + j*11
        args.chan[].sendLoop(val):
          # Busy loop, in prod we might want to yield the core/thread timeslice
          discard
        echo "Sender sent: ", val

  proc main() =
    echo "Testing if 2 threads can send data"
    echo "-----------------------------------"
    var threads: array[2, Thread[ThreadArgs]]
    var pool: TLPoolAllocator
    pool.initialize(threadID = 0)

    var chan = pool.borrow(ChannelSPSCSingle)
    chan[].initialize(itemSize = sizeof(int))

    createThread(threads[0], thread_func, ThreadArgs(ID: Receiver, chan: chan))
    createThread(threads[1], thread_func, ThreadArgs(ID: Sender, chan: chan))

    joinThread(threads[0])
    joinThread(threads[1])

    recycle(0, chan)

    echo "-----------------------------------"
    echo "Success"

  main()
