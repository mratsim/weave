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
