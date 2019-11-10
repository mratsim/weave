# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/atomics,
  ../static_config,
  ../instrumentation/contracts


type
  ChannelSpscSingle*[T: ptr] = ChannelRaw
    ## Wait-free bounded single-producer single-consumer channel
    ## that can only buffer a single item (a Picasso task)
    ## Properties:
    ##   - wait-free
    ##   - supports weak memory models
    ##   - no modulo operations
    ##   - memory-efficient: buffer the size of the capacity
    ##   - Padded to avoid false sharing
    ##   - only 1 synchronization variable.
    ##   - No extra indirection to access the item
    ##   - Linearizable
    ##   - Specialized for pointers
    ##     Using different ptr subtypes will be type-safe
    ##     but internally they are voided to avoid code duplication
    ##     due to generics: https://github.com/nim-lang/Nim/issues/12630
    ##     It is expected though that the compiler inlines (and so duplicates)
    ##     everything as the code is very small.
    ##
    ## Usage:
    ##   - Requires a pointer type
    ##   - There is no need to zero-out the padding fields
    ##   - Only trivial objects can transit (no GC, can be copied and no custom destructor)
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
  ChannelRaw = object
    pad0: array[PicassoCacheLineSize - sizeof(pointer), byte] # If used in a sequence of channels
    buffer: Atomic[pointer]

# Internal type-erased implementation
# ---------------------------------------------------------------

proc `=`(dest: var ChannelRaw,source: ChannelRaw) {.error: "A channel cannot be copied".}

func clearImpl(chan: var ChannelRaw) {.inline.} =
  chan.buffer.store(nil, moRelaxed)

func tryRecvImpl(chan: var ChannelRaw, dst: var pointer): bool {.inline, nodestroy.} =
  let p = chan.buffer.load(moAcquire)
  if p.isNil:
    return false
  # need atomic "move" - https://github.com/nim-lang/Nim/issues/12631
  dst = p
  chan.buffer.store(nil, moRelease)
  return true

func trySendImpl(chan: var ChannelRaw, src: sink pointer): bool {.inline, nodestroy.} =
  preCondition:
    not src.isNil

  let p = chan.buffer.load(moAcquire)
  if not p.isNil:
    return false
  # need atomic "sink" - https://github.com/nim-lang/Nim/issues/12631
  chan.buffer.store(src, moRelease)
  return true

# Public well-typed implementation
# ------------------------------------------------------------------------------

func initialize*[T](chan: var ChannelSpscSingle[T]) {.inline.} =
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
  clearImpl(chan)

func clear*[T](chan: var ChannelSpscSingle[T]) {.inline.} =
  ## Reinitialize the data in the channel
  ##
  ## This is not thread-safe.
  clearImpl(chan)

func tryRecv*[T](chan: var ChannelSpscSingle[T], dst: var T): bool {.inline.} =
  ## Try receiving the item buffered in the channel
  ## Returns true if successful (channel was not empty)
  ##
  ## ⚠ Use only in the consumer thread that reads from the channel.
  # Nim implicit conversion to pointer is not mutable
  chan.tryRecvImpl(cast[var pointer](dst.addr))

func trySend*[T](chan: var ChannelSpscSingle[T], src: sink T): bool {.inline.} =
  ## Try sending an item into the channel
  ## Reurns true if successful (channel was empty)
  ##
  ## ⚠ Use only in the producer thread that writes from the channel.
  chan.trySendImpl(src)

# Sanity checks
# ------------------------------------------------------------------------------
when isMainModule:
  import strutils

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
      chan: ptr Channel[ptr int]

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
      # Receives the pointer and free it
      var val: ptr int
      for j in 0 ..< 10:
        var val: ptr int
        args.chan[].recvLoop(val):
          # Busy loop, in prod we might want to yield the core/thread timeslice
          discard
        echo "                                               Receiver got: ", val[], " at address 0x", toLowerASCII toHex cast[ByteAddress](val)
        doAssert val[] == 42 + j*11
        freeShared(val)

    Worker(Sender):
      # Allocates the pointer and sends it
      doAssert args.chan.buffer.load(moRelaxed) == nil
      for j in 0 ..< 10:
        let val = createShared(int)
        val[] = 42 + j*11
        args.chan[].sendLoop(val):
          # Busy loop, in prod we might want to yield the core/thread timeslice
          discard
        echo "Sender sent: ", val[], " at address 0x", toLowerASCII toHex cast[ByteAddress](val)

  proc main() =
    echo "Testing if 2 threads can send data"
    echo "-----------------------------------"
    var threads: array[2, Thread[ThreadArgs]]
    let chan = createSharedU(Channel[ptr int]) # CreateSharedU is not zero-init
    chan[].initialize()

    createThread(threads[0], thread_func, ThreadArgs(ID: Receiver, chan: chan))
    createThread(threads[1], thread_func, ThreadArgs(ID: Sender, chan: chan))

    joinThread(threads[0])
    joinThread(threads[1])

    freeShared(chan)
    echo "-----------------------------------"
    echo "Success"

  main()
