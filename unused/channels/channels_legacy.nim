import
  # Standard library
  locks, atomics,
  system/ansi_c

# Channel (Shared memory channels)
# ----------------------------------------------------------------------------------

const
  CacheLineSize{.intdefine.} = 64 # TODO: some Samsung phone have 128 cache-line
  ChannelCacheSize*{.intdefine.} = 100

  # TODO: Add to compilation flags

type
  ChannelBufKind = enum
    Unbuffered # Unbuffered (blocking) channel
    Buffered   # Buffered (non-blocking channel)

  ChannelImplKind* = enum
    Mpmc # Multiple producer, multiple consumer
    Mpsc # Multiple producer, single consumer
    Spsc # Single producer, single consumer

  # TODO: ChannelBufKind and ChannelImplKind
  #       could probably be static enums

  ChannelLegacy*[T] = ChannelRaw # Typed channels
  ChannelRaw* = ptr ChannelObj
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
  #       We can use HList or a Table or thread-local globals
  #       to keep the list of object pools
  ChannelCache = ptr ChannelCacheObj
  ChannelCacheObj = object
    next: ChannelCache
    chan_size: int32
    chan_n: int32
    chan_impl: ChannelImplKind
    num_cached: int32
    cache: array[ChannelCacheSize, ChannelRaw]

# {.experimental: "notnil".} - TODO

# ----------------------------------------------------------------------------------

template incmod(idx, size: int32): int32 =
  (idx + 1) mod size

template decmod(idx, size: int32): int32 =
  (idx - 1) mod size

template num_items(chan: ChannelRaw): int32 =
  (chan.size + chan.tail - chan.head) mod chan.size

template is_full(chan: ChannelRaw): bool =
  chan.num_items() == chan.size - 1

template is_empty(chan: ChannelRaw): bool =
  chan.head == chan.tail

# Unbuffered / synchronous channels
# ----------------------------------------------------------------------------------

template num_items_unbuf(chan: ChannelRaw): int32 =
  # TODO: use range 0..1 but type mismatch
  chan.head

template is_full_unbuf(chan: ChannelRaw): bool =
  chan.head == 1

template is_empty_unbuf(chan: ChannelRaw): bool =
  chan.head == 0

# ChannelRaw kinds
# ----------------------------------------------------------------------------------

func channel_buffered(chan: ChannelRaw): bool =
  chan.size - 1 > 0

func channel_unbuffered(chan: ChannelRaw): bool =
  assert chan.size >= 0
  chan.size - 1 == 0

# ChannelRaw status and properties
# ----------------------------------------------------------------------------------

proc channel_closed(chan: ChannelRaw): bool {.inline.} =
  load(chan.closed, moRelaxed)

proc channel_capacity(chan: ChannelRaw): int32 {.inline.} =
  return chan.size - 1

proc channel_peek*(chan: ChannelRaw): int32 =
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

  p = cast[ptr ChannelCacheObj](c_malloc(csize_t sizeof(ChannelCacheObj)))
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

proc channel_cache_free*() =
  ## Frees the entire channel cache, including all channels

  var p = channel_cache
  var q: ChannelCache

  while not p.isNil:
    q = p.next
    for i in 0 ..< p.num_cached:
      let chan = p.cache[i]
      if not chan.buffer.isNil:
        c_free(chan.buffer)
      deinitLock(chan.head_lock)
      deinitLock(chan.tail_lock)
      c_free(chan)
    c_free(p)
    dec channel_cache_len
    p = q

  assert(channel_cache_len == 0)
  channel_cache = nil

# Channels memory ops
# ----------------------------------------------------------------------------------

proc channel_alloc*(size, n: int32, impl: ChannelImplKind): ChannelRaw =

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

  result = cast[ChannelRaw](c_malloc(csize_t sizeof(ChannelObj)))
  if result.isNil:
    raise newException(OutOfMemError, "Could not allocate memory")

  # To buffer n items, we allocate for n+1
  result.buffer = cast[ptr UncheckedArray[byte]](c_malloc(csize_t (n+1)*size))
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

proc channel_free*(chan: ChannelRaw) =
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
      p = p.next

  if not chan.buffer.isNil:
    c_free(chan.buffer)

  deinitLock(chan.head_lock)
  deinitLock(chan.tail_lock)

  c_free(chan)

# MPMC Channels (Multi-Producer Multi-Consumer)
# ----------------------------------------------------------------------------------

proc channel_send_unbuffered_mpmc(
       chan: ChannelRaw,
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
       chan: ChannelRaw,
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
       chan: ChannelRaw,
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
       chan: ChannelRaw,
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

proc channel_close_mpmc(chan: ChannelRaw): bool =
  # Unsynchronized

  if chan.channel_closed():
    # ChannelRaw already closed
    return false

  store(chan.closed, true, moRelaxed)
  return true

proc channel_open_mpmc(chan: ChannelRaw): bool =
  # Unsynchronized

  if not chan.channel_closed:
    # ChannelRaw already open
    return false

  store(chan.closed, false, moRelaxed)
  return true

# MPSC Channels (Multi-Producer Single-Consumer)
# ----------------------------------------------------------------------------------

proc channel_send_mpsc(
       chan: ChannelRaw,
       data: sink pointer,
       size: int32
      ): bool =
  # Cannot be inline due to function table
  channel_send_mpmc(chan, data, size)

proc channel_recv_unbuffered_mpsc(
       chan: ChannelRaw,
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
       chan: ChannelRaw,
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

proc channel_close_mpsc(chan: ChannelRaw): bool =
  # Unsynchronized
  assert not chan.isNil

  if chan.channel_closed():
    # Already closed
    return false

  chan.closed.store(true, moRelaxed)
  return true

proc channel_open_mpsc(chan: ChannelRaw): bool =
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
       chan: ChannelRaw,
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
       chan: ChannelRaw,
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
       chan: ChannelRaw,
       data: pointer,
       size: int32
      ): bool =
  # Cannot be inline due to function table
  channel_recv_mpsc(chan, data, size)

proc channel_close_spsc(chan: ChannelRaw): bool =
  # Unsynchronized
  assert not chan.isNil

  if chan.channel_closed():
    # Already closed
    return false

  chan.closed.store(true, moRelaxed)
  return true

proc channel_open_spsc(chan: ChannelRaw): bool =
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

proc channel_send(chan: ChannelRaw, data: sink pointer, size: int32): bool {.inline.}=
  ## Send item to the channel (FIFO queue)
  ## (Insert at last)
  send_fn[chan.impl](chan, data, size)

proc channel_receive(chan: ChannelRaw, data: pointer, size: int32): bool {.inline.}=
  ## Receive an item from the channel
  ## (Remove the first item)
  recv_fn[chan.impl](chan, data, size)

proc channel_close(chan: ChannelRaw): bool {.inline.}=
  ## Close a channel
  close_fn[chan.impl](chan)

proc channel_open(chan: ChannelRaw): bool {.inline.}=
  ## (Re)open a channel
  close_fn[chan.impl](chan)

proc channel_send*[T](chan: ChannelLegacy[T], data: sink T, size: int32): bool {.inline.}=
  ## Send item to the channel (FIFO queue)
  ## (Insert at last)
  send_fn[chan.impl](chan, data.unsafeAddr, size)

proc channel_receive*[T](chan: ChannelLegacy[T], data: ptr T, size: int32): bool {.inline.}=
  ## Receive an item from the channel
  ## (Remove the first item)
  recv_fn[chan.impl](chan, data, size)

# Weave API
# ----------------------------------------------------------------------------------

func trySend*[T](c: ChannelLegacy[T], src: sink T): bool {.inline.} =
  channel_send(c, src, int32 sizeof(src))

func tryRecv*[T](c: ChannelLegacy[T], dst: var T): bool {.inline.} =
  channel_receive(c, dst.addr, int32 sizeof(dst))

func peek*[T](c: ChannelLegacy[T]): int32 =
  channel_peek(c)

proc initialize*[T](c: var ChannelLegacy[T], size: int32) =
  c = channel_alloc(int32 sizeof(T), size, Mpsc)

proc delete*[T](c: var ChannelLegacy[T]) =
  channel_free(c)

# Tests
# ----------------------------------------------------------------------------------

when isMainModule:

  type
    Pthread {.importc: "pthread_t", header: "<sys/types.h>".} = distinct culong
    PthreadAttr* {.byref, importc: "pthread_attr_t", header: "<sys/types.h>".} = object
    Errno* = distinct cint

  proc pthread_create[T](
        thread: var Pthread,
        attr: ptr PthreadAttr, # In Nim this is a var and how Nim sets a custom stack
        fn: proc (x: ptr T): pointer {.thread, noconv.},
        arg: ptr T
    ): Errno {.header: "<sys/types.h>".}

  proc pthread_join(
        thread: Pthread,
        thread_exit_status: ptr pointer
      ): Errno {.header: "<pthread.h>".}

  template channel_send_loop(chan: ChannelRaw,
                        data: sink pointer,
                        size: int32,
                        body: untyped): untyped =
    while not channel_send(chan, data, size):
      body

  template channel_receive_loop(chan: ChannelRaw,
                          data: pointer,
                          size: int32,
                          body: untyped): untyped =
    while not channel_receive(chan, data, size):
      body

  when not compileOption("threads"):
    {.error: "This requires --threads:on compilation flag".}

  # Without threads:on or release,
  # worker threads will crash on popFrame

  import unittest, strformat

  type ThreadArgs = object
    ID: int32
    chan: ChannelRaw

  template Worker(id: int32, body: untyped): untyped {.dirty.}=
    if args.ID == id:
      body

  template Master(body: untyped): untyped =
    Worker(0, body)

  const Sender = 1
  const Receiver = 0

  proc runSuite(
             name: string,
             fn: proc(args: ptr ThreadArgs): pointer {.noconv, gcsafe.}
           ) =
    suite name:
      var chan: ChannelRaw

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
              chan = channel_alloc(size = int.sizeof.int32, n = 7, impl)
              check:
                channel_peek(chan) == 0
                channel_capacity(chan) == 7
                channel_buffered(chan) == true
                channel_unbuffered(chan) == false
                chan.impl == impl

            var threads: array[2, Pthread]
            var args = [
              ThreadArgs(ID: 0, chan: chan),
              ThreadArgs(ID: 1, chan: chan)
            ]

            discard pthread_create(threads[0], nil, fn, args[0].addr)
            discard pthread_create(threads[1], nil, fn, args[1].addr)

            discard pthread_join(threads[0], nil)
            discard pthread_join(threads[1], nil)

            channel_free(chan)

  # ----------------------------------------------------------------------------------

  proc thread_func(args: ptr ThreadArgs): pointer {.noconv.} =

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
        channel_receive_loop(args.chan, val.addr, val.sizeof.int32):
          # Busy loop, normally it should yield
          discard
        check: val == 42 + j*11

    Worker(Sender):
      var val: int
      check: channel_peek(args.chan) == 0
      for j in 0 ..< 3:
        val = 42 + j*11
        channel_send_loop(args.chan, val.addr, val.sizeof.int32):
          # Busy loop, normally it should yield
          discard

    return nil

  runSuite("[ChannelRaw] 2 threads can send data", thread_func)

  # ----------------------------------------------------------------------------------

  iterator pairs(chan: ChannelRaw, T: typedesc): (int, T) =
    var
      i: int
      x: T
    while not(channel_closed(chan)) or (channel_peek(chan) > 0):
      let r = channel_receive(chan, x.addr, x.sizeof.int32)
      # printf("x: %d, r: %d\n", x, r)
      if not r:
        continue
      else:
        yield (i, x)
        inc i

  proc thread_func_2(args: ptr ThreadArgs): pointer {.noconv.}=

    # Worker RECEIVER:
    # ---------
    # <- chan until closed and empty
    #
    # Worker SENDER:
    # ---------
    # chan <- 42, 53, 64, ...

    const N = 100

    Worker(Receiver):
      for j, val in pairs(args.chan, int):
        # TODO: Need special handling that doesn't allocate
        #       in thread with no GC
        #       when check fails
        #
        check: val == 42 + j*11

    Worker(Sender):
      var val: int
      check: channel_peek(args.chan) == 0
      for j in 0 ..< N:
        val = 42 + j*11
        channel_send_loop(args.chan, val.addr, int.sizeof.int32):
          discard
      discard channel_close(args.chan)

    return nil

  runSuite("[ChannelRaw] channel_close, channel_free, channel_cache", thread_func_2)

  # ----------------------------------------------------------------------------------

  proc is_cached(chan: ChannelRaw): bool =
    assert not chan.isNil

    var p = channel_cache

    while not p.isNil:
      if chan.itemsize == p.chan_size and
         chan.size-1 == p.chan_n      and
         chan.impl == p.chan_impl:
        for i in 0 ..< p.num_cached:
          if chan == p.cache[i]:
            return true
        # No more channel in cache can match
        return false
      p = p.next
    return false

  suite "[ChannelRaw] ChannelRaw caching implementation":

    # Start from clean cache slate
    channel_cache_free()

    test "Explicit caches allocation":
      check:
        channel_cache_alloc(int32 sizeof(char), 4, Mpmc)
        channel_cache_alloc(int32 sizeof(int32), 8, Mpsc)
        channel_cache_alloc(int32 sizeof(ptr float64), 16, Spsc)

        # Don't create existing channel cache
        not channel_cache_alloc(int32 sizeof(char), 4, Mpmc)
        not channel_cache_alloc(int32 sizeof(int32), 8, Mpsc)
        not channel_cache_alloc(int32 sizeof(ptr float64), 16, Spsc)

      check:
        channel_cache.chan_impl == Spsc
        channel_cache.next.chan_impl == Mpsc
        channel_cache.next.next.chan_impl == Mpmc

        channel_cache_len == 3

    # ---------------------------------
    var chan, stash: array[10, ChannelRaw]

    test "Implicit caches allocation":

      chan[0] = channel_alloc(int32 sizeof(char), 4, Mpmc)
      chan[1] = channel_alloc(int32 sizeof(int32), 8, Mpsc)
      chan[2] = channel_alloc(int32 sizeof(ptr float64), 16, Spsc)

      chan[3] = channel_alloc(int32 sizeof(char), 5, Mpmc)
      chan[4] = channel_alloc(int32 sizeof(int64), 8, Mpsc)
      chan[5] = channel_alloc(int32 sizeof(ptr float64), 16, Mpsc)

      # We have caches ready to store specific channel kinds
      check: channel_cache_len == 6 # Cumulated with previous test
      # But they are not in cache while in use
      check:
        not chan[0].is_cached()
        not chan[1].is_cached()
        not chan[2].is_cached()
        not chan[3].is_cached()
        not chan[4].is_cached()
        not chan[5].is_cached()

    test "Freed channels are returned to cache":
      stash[0..5] = chan.toOpenArray(0, 5)
      for i in 0 .. 5:
        # Free the channels
        channel_free(chan[i])

      check:
        stash[0].is_cached()
        stash[1].is_cached()
        stash[2].is_cached()
        stash[3].is_cached()
        stash[4].is_cached()
        stash[5].is_cached()

    test "Cached channels are being reused":

      chan[6] = channel_alloc(int32 sizeof(char), 4, Mpmc)
      chan[7] = channel_alloc(int32 sizeof(int32), 8, Mpsc)
      chan[8] = channel_alloc(int32 sizeof(ptr float32), 16, Spsc)
      chan[9] = channel_alloc(int32 sizeof(ptr float64), 16, Spsc)

      # All (itemsize, queue size, implementation) were already allocated
      check: channel_cache_len == 6

      # We reused old channels from cache
      check:
        chan[6] == stash[0]
        chan[7] == stash[1]
        chan[8] == stash[2]
        # chan[9] - required a fresh alloc

    test "Clearing the cache":

      stash[6..9] = chan.toOpenArray(6, 9)

      for i in 6 .. 9:
        channel_free(chan[i])

      check:
        stash[6].is_cached()
        stash[7].is_cached()
        stash[8].is_cached()
        stash[9].is_cached()

      channel_cache_free()

      # Check that nothing is cached anymore
      for i in 0 .. 9:
        check: not stash[i].is_cached()
      # And length is reset to 0
      check: channel_cache_len == 0

      # Cache can grow again
      chan[0] = channel_alloc(int32 sizeof((int, float, int32, uint)), 1, Spsc)
      chan[1] = channel_alloc(int32 sizeof(int32), 0, Spsc)
      chan[2] = channel_alloc(int32 sizeof(int32), 0, Spsc)

      check: channel_cache_len == 2

      # Interleave cache clear and channel free
      channel_cache_free()
      check: channel_cache_len == 0

      channel_free(chan[0])
      channel_free(chan[1])
      channel_free(chan[2])
