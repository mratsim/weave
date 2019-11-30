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
  ChannelLazyFlowvar* = object
    ## A type-erased SPSC channel for LazyFlowvar.
    ##
    ## Motivation, when LazyFlowvar needs to be converted
    ## from stack-allocated memory to heap to extended their lifetime
    ## we have no type information at all as the whole runtime
    ## and especially tasks does not retain it.
    next*{.align: WV_CacheLinePadding.}: Atomic[pointer] # Concurrent intrusive lists
    full: Atomic[bool]
    itemSize*: uint8
    totalSize*: uint8
    buffer*: UncheckedArray[byte]

proc `=`(
    dest: var ChannelLazyFlowvar,
    source: ChannelLazyFlowvar
  ) {.error: "A channel cannot be copied".}

proc newChannelLazyFlowvar*(pool: var TLPoolAllocator, itemsize: SomeInteger): ptr ChannelLazyFlowvar {.inline.} =
  preCondition: itemsize.int in 0 .. int high(uint8)
  preCondition: itemSize.int +
                sizeof(result.next) +
                sizeof(result.itemsize) +
                sizeof(result.full) < WV_MemBlockSize # we could use 256 but 255 is nice on "totalSize"

  result = pool.borrow(ChannelLazyFlowvar)
  result.itemsize = uint8(itemsize)
  result.full.store(false, moRelaxed)

  # TODO Address Sanitizer / memory poisoning

func isEmpty*(chan: var ChannelLazyFlowvar): bool {.inline.} =
  not chan.full.load(moAcquire)

func tryRecv*[T](chan: var ChannelLazyFlowvar, dst: var T): bool {.inline.} =
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

func trySend*[T](chan: var ChannelLazyFlowvar, src: sink T): bool {.inline.} =
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

  template sendLoop[T](chan: var ChannelLazyFlowvar,
                       data: sink T,
                       body: untyped): untyped =
    while not chan.trySend(data):
      body

  template recvLoop[T](chan: var ChannelLazyFlowvar,
                       data: var T,
                       body: untyped): untyped =
    while not chan.tryRecv(data):
      body

  type
    ThreadArgs = object
      ID: WorkerKind
      chan: ptr ChannelLazyFlowvar

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

    let chan = pool.newChannelLazyFlowvar(sizeof(int))

    createThread(threads[0], thread_func, ThreadArgs(ID: Receiver, chan: chan))
    createThread(threads[1], thread_func, ThreadArgs(ID: Sender, chan: chan))

    joinThread(threads[0])
    joinThread(threads[1])

    recycle(0, chan)

    echo "-----------------------------------"
    echo "Success"

  main()
