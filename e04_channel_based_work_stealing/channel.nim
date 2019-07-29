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
  if result.buffer.isNim:
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

proc channel_free(chan: Channel) =
  if chan.isNil:
    return

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
