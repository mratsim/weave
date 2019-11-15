# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/atomics,
  ../config

type
  ChannelSpscSingleObject*[T] = object
    ## Wait-free bounded single-producer single-consumer channel
    ## that can only buffer a single item
    ## Properties:
    ##   - wait-free
    ##   - supports weak memory models
    ##   - no modulo operations
    ##   - memory-efficient: buffer the size of the capacity
    ##   - Padded to avoid false sharing
    ##   - only 1 synchronization variable.
    ##   - No extra indirection to access the item, the buffer is inline the channel
    ##   - Linearizable
    ##
    ## Requires T to fit in a CacheLine
    ##
    ## Usage:
    ##   - Must be heap-allocated
    ##   - There is no need to zero-out the padding fields
    ##   - The content of the channel is not destroyed upon channel destruction
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
    pad0: array[PI_CacheLineSize, byte] # If used in a sequence of channels
    buffer: T
    pad1: array[PI_CacheLineSize  - sizeof(T), byte]
    full: Atomic[bool]

proc `=`[T](
    dest: var ChannelSpscSingleObject[T],
    source: ChannelSpscSingleObject[T]
  ) {.error: "A channel cannot be copied".}

func initialize*[T](chan: var ChannelSpscSingleObject[T]) {.inline.} =
  ## Creates a new Shared Memory Single Producer Single Consumer Bounded channel
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
  chan.buffer = default(T)
  chan.full.store(false, moRelaxed)

func clear*(chan: var ChannelSpscSingleObject) {.inline.} =
  ## Reinitialize the data in the channel
  ##
  ## This is not thread-safe.
  if chan.full.load(moRelaxed) == true:
    `=destroy`(chan.buffer)
    chan.full.store(moRelaxed) = false

func tryRecv*[T](chan: var ChannelSpscSingleObject[T], dst: var T): bool {.inline.} =
  ## Try receiving the item buffered in the channel
  ## Returns true if successful (channel was not empty)
  ##
  ## ⚠ Use only in the consumer thread that reads from the channel.
  let full = chan.full.load(moAcquire)
  if not full:
    return false
  dst = move chan.buffer
  chan.full.store(false, moRelease)
  return true

func trySend*[T](chan: var ChannelSpscSingleObject[T], src: sink T): bool {.inline.} =
  ## Try sending an item into the channel
  ## Reurns true if successful (channel was empty)
  ##
  ## ⚠ Use only in the producer thread that writes from the channel.
  let full = chan.full.load(moAcquire)
  if full:
    return false
  `=sink`(chan.buffer, src)
  chan.full.store(true, moRelease)
  return true

# Sanity checks
# ------------------------------------------------------------------------------
when isMainModule:
  ../memory/allocs

  when not compileOption("threads"):
    {.error: "This requires --threads:on compilation flag".}

  template sendLoop[T](chan: var ChannelSpscSingleObject[T],
                       data: sink T,
                       body: untyped): untyped =
    while not chan.trySend(data):
      body

  template recvLoop[T](chan: var ChannelSpscSingleObject[T],
                       data: var T,
                       body: untyped): untyped =
    while not chan.tryRecv(data):
      body

  type
    ThreadArgs = object
      ID: WorkerKind
      chan: ptr ChannelSpscSingleObject[int]

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
    let chan = pi_alloc(ChannelSpscSingle[int])
    chan[].initialize()

    createThread(threads[0], thread_func, ThreadArgs(ID: Receiver, chan: chan))
    createThread(threads[1], thread_func, ThreadArgs(ID: Sender, chan: chan))

    joinThread(threads[0])
    joinThread(threads[1])

    pi_free(chan)
    echo "-----------------------------------"
    echo "Success"

  main()
