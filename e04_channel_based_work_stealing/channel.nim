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

{.experimental: "notnil".}
# ----------------------------------------------------------------------------------

func incmod(idx, size: int32): int32 {.inline.} =
  (idx + 1) mod size

func decmod(idx, size: int32): int32 {.inline.} =
  (idx - 1) mod size

func num_items(chan: Channel not nil): int32 {.inline.} =
  (chan.size + chan.tail - chan.head) mod chan.size

func is_full(chan: Channel not nil): bool {.inline.} =
  chan.num_items() == chan.size - 1

func is_empty(chan: Channel not nil): bool {.inline.} =
  chan.head == chan.tail

# Unbuffered / synchronous channels
# ----------------------------------------------------------------------------------

func num_items_unbuf(chan: Channel not nil): int32 {.inline.} =
  # TODO: use range 0..1 but type mismatch
  chan.head

func is_full_unbuf(chan: Channel not nil): bool {.inline.} =
  chan.head == 1

func is_empty_unbuf(chan: Channel not nil): bool {.inline.} =
  chan.head == 0

# Channel kinds
# ----------------------------------------------------------------------------------

func channel_buffered(chan: Channel not nil): bool =
  chan.size - 1 > 0

func channel_unbuffered(chan: Channel not nil): bool =
  assert chan.size >= 0
  chan.size - 1 == 0

# Channel status
# ----------------------------------------------------------------------------------

proc channel_closed(chan: Channel): bool {.inline.}=
  load(chan.closed, moRelaxed)

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

proc channel_alloc(size, n: int32, impl: ChannelImplKind): Channel not nil =

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
  result.closed = false
  result.size = n+1
  result.itemsize = size
  result.head = 0
  result.tail = 0

  when ChannelCacheSize > 0:
    # Allocate a cache as well if one of the proper size doesn't exist
    discard channel_cache_alloc(size, n, impl)

proc channel_free(chan: Channel not nil) =
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

# MPMC Channels (Multi-Producer Multi Consumer)
# ----------------------------------------------------------------------------------

proc channel_send_unbuffered_mpmc(
       chan: Channel not nil,
       data: pointer not nil,
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
       chan: Channel not nil,
       data: pointer not nil,
       size: int32
     ): bool =

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
       chan: Channel not nil,
       data: pointer not nil,
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
       chan: Channel not nil,
       data: pointer not nil,
       size: int32
     ): bool =

  if channel_unbuffered(chan):
    return channem_recv_unbuffered_mpmc(chan, data, size)

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

  chan.head = chan.head.incmod(chan.head, chan.size)

  release(chan.head_lock)
  return true

proc channel_close_mpmc(chan: Channel not nil): bool =
  # Unsynchronized

  if chan.channel_closed():
    # Channel already closed
    return false

  store(chan.closed, true, moRelaxed)
  return true

proc channel_open_mpmc(chan: Channel not nil): bool =
  # Unsynchronized

  if not chan.channel_closed:
    # CHannel already open
    return false

  store(chan.closed, false, moRelaxed)
  return true
