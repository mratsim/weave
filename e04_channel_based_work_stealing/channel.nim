import
  # Standard library
  locks, atomics,
  # Internal
  ./primitives/[c, threads]

# Channel (Shared memory channels)
# ----------------------------------------------------------------------------------

const
  CacheLineSize{.intdefine.} = 64 # TODO: some Samsung phone have 128 cache-line
  ChannelCacheSize{.intdefine.} = 100

  # TODO: Add to compilation flags

type
  ChannelBufKind = enum
    Unbuffered # Unbuffered (blocking) channel
    Buffered   # Buffered (non-blocking channel)

  ChannelImplKind = enum
    Mpmc # Multiple producer, multiple consumer
    Mpsc # Multiple producer, single consumer
    Spsc # Single producer, single consumer

  # TODO: ChannelBufKind and ChannelImplKind
  #       could probably be static enums

  Channel = ptr ChannelObj
  ChannelObj = object
    head_lock, tail_lock: Lock
    owner: int32
    impl: ChannelImplKind
    closed: Atomic[bool]
    size: int32
    itemsize: int32 # up to itemsize bytes can be exchanged over this channel
    head: int32     # Items are taken from head and new items are inserted at tail
    pad: array[CacheLineSize, byte] # Separate by at-least a cache line
    tail: int32
    buffer: ptr UncheckedArray[byte]

  # TODO: Replace this cache by generic ObjectPools
  #       We can use HList or a Table to keep the list of object pools
  ChannelCache = ptr ChannelCacheObj
  ChannelCacheObj = object
    next: ChannelCache
    chan_size: int32
    chan_n: int32
    chan_impl: ChannelImplKind
    num_cached: int32
    cache: array[ChannelCacheSize, Channel]

# {.experimental: "notnil".} - TODO

# ----------------------------------------------------------------------------------

func incmod(idx, size: int32): int32 {.inline.} =
  (idx + 1) mod size

func decmod(idx, size: int32): int32 {.inline.} =
  (idx - 1) mod size

func num_items(chan: Channel): int32 {.inline.} =
  (chan.size + chan.tail - chan.head) mod chan.size

func is_full(chan: Channel): bool {.inline.} =
  chan.num_items() == chan.size - 1

func is_empty(chan: Channel): bool {.inline.} =
  chan.head == chan.tail

# Unbuffered / synchronous channels
# ----------------------------------------------------------------------------------

func num_items_unbuf(chan: Channel): int32 {.inline.} =
  # TODO: use range 0..1 but type mismatch
  chan.head

func is_full_unbuf(chan: Channel): bool {.inline.} =
  chan.head == 1

func is_empty_unbuf(chan: Channel): bool {.inline.} =
  chan.head == 0

# Channel kinds
# ----------------------------------------------------------------------------------

func channel_buffered(chan: Channel): bool =
  chan.size - 1 > 0

func channel_unbuffered(chan: Channel): bool =
  assert chan.size >= 0
  chan.size - 1 == 0

# Channel status and properties
# ----------------------------------------------------------------------------------

proc channel_closed(chan: Channel): bool {.inline.} =
  load(chan.closed, moRelaxed)

proc channel_capacity(chan: Channel): int32 {.inline.} =
  return chan.size - 1

proc channel_peek(chan: Channel): int32 =
  if chan.channel_unbuffered():
    return num_items_unbuf(chan)
  return num_items(chan)

# Per-thread channel cache
# ----------------------------------------------------------------------------------

var channel_cache {.threadvar.}: ChannelCache
var channel_cache_len {.threadvar.}: int32

proc channel_cache_alloc(
       size, n: int32,
       impl: ChannelImplKind): bool =
  ## Allocate a free list for storing channels of a given type

  var p = channel_cache

  # Avoid multiple free lists for the exact same type of channel
  while not p.isNil:
    if size == p.chan_size   and
          n == p.chan_n      and
          impl == p.chan_impl:
      return false
    p = p.next

  p = malloc(ChannelCacheObj)
  if p.isNil:
    raise newException(OutOfMemError, "Could not allocate memory")

  p.chan_size = size
  p.chan_n = n
  p.chan_impl = impl
  p.num_cached = 0

  p.next = channel_cache
  channel_cache = p
  inc channel_cache_len

  return true

proc channel_cache_free() =
  ## Frees the entire channel cache, including all channels

  var p = channel_cache
  var q: ChannelCache

  while not p.isNil:
    q = p.next
    for i in 0 ..< p.num_cached:
      let chan = p.cache[i]
      if not chan.buffer.isNil:
        free(chan.buffer)
      deinitLock(chan.head_lock)
      deinitLock(chan.tail_lock)
      free(chan)
    free(p)
    dec channel_cache_len
    p = q

  assert(channel_cache_len == 0)
  channel_cache = nil

proc channel_alloc(size, n: int32, impl: ChannelImplKind): Channel =

  when ChannelCacheSize > 0:
    var p = channel_cache

    while not p.isNil:
      if size == p.chan_size   and
            n == p.chan_n      and
            impl == p.chan_impl:
        # Check if free list contains channel
        if p.num_cached > 0:
          dec p.num_cached
          result = p.cache[p.num_cached]
          assert(result.is_empty())
          return
        else:
          # All the other lists in cache won't match
          break
      p = p.next

  result = malloc(ChannelObj)
  if result.isNil:
    raise newException(OutOfMemError, "Could not allocate memory")

  # To buffer n items, we allocate for n+1
  result.buffer = malloc(byte, (n+1) * size)
  if result.buffer.isNil:
    raise newException(OutOfMemError, "Could not allocate memory")

  initLock(result.head_lock)
  initLock(result.tail_lock)

  result.owner = -1 # TODO
  result.impl = impl
  result.closed.store(false, moRelaxed) # We don't need atomic here, how to?
  result.size = n+1
  result.itemsize = size
  result.head = 0
  result.tail = 0

  when ChannelCacheSize > 0:
    # Allocate a cache as well if one of the proper size doesn't exist
    discard channel_cache_alloc(size, n, impl)

proc channel_free(chan: Channel) =
  # if chan.isNil:
  #   return

  when ChannelCacheSize > 0:
    var p = channel_cache
    while not p.isNil:
      if chan.itemsize == p.chan_size and
         chan.size-1 == p.chan_n      and
         chan.impl == p.chan_impl:
        if p.num_cached < ChannelCacheSize:
          # If space left in cache, cache it
          p.cache[p.num_cached] = chan
          inc p.num_cached
          return
        else:
          # All the other lists in cache won't match
          break

  if not chan.buffer.isNil:
    free(chan.buffer)

  deinitLock(chan.head_lock)
  deinitLock(chan.tail_lock)

  free(chan)

# MPMC Channels (Multi-Producer Multi-Consumer)
# ----------------------------------------------------------------------------------

proc channel_send_unbuffered_mpmc(
       chan: Channel,
       data: sink pointer,
       size: int32
     ): bool =
  if chan.is_full_unbuf():
    return false

  acquire(chan.head_lock)

  if chan.is_full_unbuf():
    # Another thread was faster
    release(chan.head_lock)
    return false

  assert chan.is_empty_unbuf()
  assert size <= chan.itemsize
  copyMem(chan.buffer, data, size)

  chan.head = 1

  release(chan.head_lock)
  return true

proc channel_send_mpmc(
       chan: Channel,
       data: sink pointer,
       size: int32
     ): bool =

  assert not chan.isNil # TODO not nil compiler constraint
  assert not data.isNil

  if channel_unbuffered(chan):
    return channel_send_unbuffered_mpmc(chan, data, size)

  if chan.is_full():
    return false

  acquire(chan.tail_lock)

  if chan.is_full():
    # Another thread was faster
    release(chan.tail_lock)
    return false

  assert not chan.is_full
  assert size <= chan.itemsize

  copyMem(
    chan.buffer[chan.tail * chan.itemsize].addr,
    data,
    size
  )

  chan.tail = chan.tail.incmod(chan.size)

  release(chan.tail_lock)
  return true

proc channel_recv_unbuffered_mpmc(
       chan: Channel,
       data: pointer,
       size: int32
     ): bool =
  if chan.is_empty_unbuf():
    return false

  acquire(chan.head_lock)

  if chan.is_empty_unbuf():
    # Another thread was faster
    release(chan.head_lock)
    return false

  assert chan.is_full_unbuf()
  assert size <= chan.itemsize
  copyMem(
    data,
    chan.buffer,
    size
  )

  chan.head = 0
  assert chan.is_empty_unbuf

  release(chan.head_lock)
  return true

proc channel_recv_mpmc(
       chan: Channel,
       data: pointer,
       size: int32
     ): bool =

  assert not chan.isNil # TODO not nil compiler constraint
  assert not data.isNil

  if channel_unbuffered(chan):
    return channel_recv_unbuffered_mpmc(chan, data, size)

  if chan.is_empty():
    return false

  acquire(chan.head_lock)

  if chan.is_empty():
    # Another thread took the last data
    release(chan.head_lock)
    return false

  assert not chan.is_empty()
  assert size <= chan.itemsize
  copyMem(
    data,
    chan.buffer[chan.head * chan.itemsize].addr,
    size
  )

  chan.head = chan.head.incmod(chan.size)

  release(chan.head_lock)
  return true

proc channel_close_mpmc(chan: Channel): bool =
  # Unsynchronized

  if chan.channel_closed():
    # Channel already closed
    return false

  store(chan.closed, true, moRelaxed)
  return true

proc channel_open_mpmc(chan: Channel): bool =
  # Unsynchronized

  if not chan.channel_closed:
    # CHannel already open
    return false

  store(chan.closed, false, moRelaxed)
  return true

# MPSC Channels (Multi-Producer Single-Consumer)
# ----------------------------------------------------------------------------------

proc channel_send_mpsc(
       chan: Channel,
       data: sink pointer,
       size: int32
      ): bool =
  # Cannot be inline due to function table
  channel_send_mpmc(chan, data, size)

proc channel_recv_unbuffered_mpsc(
       chan: Channel,
       data: pointer,
       size: int32
      ): bool =
  # Single consumer, no lock needed on reception

  if chan.is_empty_unbuf():
    return false

  assert chan.is_full_unbuf
  assert size <= chan.itemsize

  copyMem(data, chan.buffer, size)

  fence(moSequentiallyConsistent)

  chan.head = 0
  return true

proc channel_recv_mpsc(
       chan: Channel,
       data: pointer,
       size: int32
      ): bool =
  # Single consumer, no lock needed on reception

  assert not chan.isNil # TODO not nil compiler constraint
  assert not data.isNil

  if channel_unbuffered(chan):
    return channel_recv_unbuffered_mpsc(chan, data, size)

  if chan.is_empty():
    return false

  assert not chan.is_empty()
  assert size <= chan.itemsize

  copyMem(
    data,
    chan.buffer[chan.head * chan.itemsize].addr,
    size
  )

  let newHead = chan.head.incmod(chan.size)

  fence(moSequentiallyConsistent)

  chan.head = newHead
  return true

proc channel_close_mpsc(chan: Channel): bool =
  # Unsynchronized
  assert not chan.isNil

  if chan.channel_closed():
    # Already closed
    return false

  chan.closed.store(true, moRelaxed)
  return true

proc channel_open_mpsc(chan: Channel): bool =
  # Unsynchronized
  assert not chan.isNil

  if not chan.channel_closed():
    # Already open
    return false

  chan.closed.store(false, moRelaxed)
  return true

# SPSC Channels (Single-Producer Single-Consumer)
# ----------------------------------------------------------------------------------

proc channel_send_unbuffered_spsc(
       chan: Channel,
       data: sink pointer,
       size: int32
      ): bool =
  if chan.is_full_unbuf:
    return false

  assert chan.is_empty_unbuf
  assert size <= chan.itemsize
  copyMem(chan.buffer, data, size)

  fence(moSequentiallyConsistent)

  chan.head = 1
  return true

proc channel_send_spsc(
       chan: Channel,
       data: sink pointer,
       size: int32
      ): bool =
  assert not chan.isNil
  assert not data.isNil

  if chan.channel_unbuffered():
    return channel_send_unbuffered_spsc(chan, data, size)

  if chan.is_full():
    return false

  assert not chan.is_full()
  assert size <= chan.itemsize
  copyMem(
    chan.buffer[chan.tail * chan.itemsize].addr,
    data,
    size
  )

  let newTail = chan.tail.incmod(chan.size)

  fence(moSequentiallyConsistent)

  chan.tail = newTail
  return true

proc channel_recv_spsc(
       chan: Channel,
       data: pointer,
       size: int32
      ): bool =
  # Cannot be inline due to function table
  channel_recv_mpsc(chan, data, size)

proc channel_close_spsc(chan: Channel): bool =
  # Unsynchronized
  assert not chan.isNil

  if chan.channel_closed():
    # Already closed
    return false

  chan.closed.store(true, moRelaxed)
  return true

proc channel_open_spsc(chan: Channel): bool =
  # Unsynchronized
  assert not chan.isNil

  if not chan.channel_closed():
    # Already open
    return false

  chan.closed.store(false, moRelaxed)
  return true

# "Generic" dispatch
# ----------------------------------------------------------------------------------

const
  send_fn = [
    Mpmc: channel_send_mpmc,
    Mpsc: channel_send_mpsc,
    Spsc: channel_send_spsc
  ]

  recv_fn = [
    Mpmc: channel_recv_mpmc,
    Mpsc: channel_recv_mpsc,
    Spsc: channel_recv_spsc
  ]

  close_fn = [
    Mpmc: channel_close_mpmc,
    Mpsc: channel_close_mpsc,
    Spsc: channel_close_spsc
  ]

  open_fn = [
    Mpmc: channel_open_mpmc,
    Mpsc: channel_open_mpsc,
    Spsc: channel_open_spsc
  ]

proc channel_send(chan: Channel, data: sink pointer, size: int32): bool {.inline.}=
  ## Send item to the channel (FIFO queue)
  ## (Insert at last)
  send_fn[chan.impl](chan, data, size)

proc channel_receive(chan: Channel, data: pointer, size: int32): bool {.inline.}=
  ## Receive an item from the channel
  ## (Remove the first item)
  recv_fn[chan.impl](chan, data, size)

proc channel_close(chan: Channel): bool {.inline.}=
  ## Close a channel
  close_fn[chan.impl](chan)

proc channel_open(chan: Channel): bool {.inline.}=
  ## (Re)open a channel
  close_fn[chan.impl](chan)

template channel_send(chan: Channel,
                      data: sink pointer,
                      size: int32,
                      body: untyped): untyped =
  while not channel_send(chan, data, size):
    body

template channel_receive(chan: Channel,
                         data: sink pointer,
                         size: int32,
                         body: untyped): untyped =
  while not channel_send(chan, data, size):
    body

# Tests
# ----------------------------------------------------------------------------------

when isMainModule:
  import unittest, strformat

  type Thread_args = object
    ID: int32
    chan: Channel

  template Worker(id: int32, body: untyped): untyped =
    if A.ID == id:
      body

  template Master(body: untyped): untyped =
    Worker(0, body)

  proc thread_func(args: pointer): pointer =

    let A = cast[ptr Thread_args](args)

    const Sender = 1
    const Receiver = 0

    #
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
    #

    Worker(Receiver):
      var val: int
      for j in 0 ..< 3:
        channel_receive(A.chan, val.addr, sizeof(val).int32):
          # Busy loop, normally it should yield
          discard
        doAssert(val == 42 + j*11)

    Worker(Sender):
      var val: int
      doAssert(channel_peek(A.chan) == 0)
      for j in 0 ..< 3:
        val = 42 + j*11
        channel_send(A.chan, val.addr, sizeof(val).int32):
          # Busy loop, normally it should yield
          discard

    return nil

  suite "Channel implementations test":

    var chan: Channel

    for impl in Mpmc .. Spsc:
      for i in Unbuffered .. Buffered:
        test &"{i:10} {impl} channels":
          if i == Unbuffered:
            chan = channel_alloc(size = 32, n = 0, impl)
            check:
              channel_peek(chan) == 0
              channel_capacity(chan) == 0
              channel_buffered(chan) == false
              channel_unbuffered(chan) == true
              chan.impl == impl
          else:
            chan = channel_alloc(size = sizeof(int).int32, n = 7, impl)
            check:
              channel_peek(chan) == 0
              channel_capacity(chan) == 7
              channel_buffered(chan) == true
              channel_unbuffered(chan) == false
              chan.impl == impl
