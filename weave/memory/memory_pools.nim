# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# A thread-safe fixed size memory pool
#
# The goal is to hand out fixed size memory block
# to use for objects that may be created in one thread
# but released in another. In producer-consumer scenario
# where there is a imbalance between producer and consumer
# if naive thread-local caches are used
# the receiver cache will grow unbounded while the producer cache
# will always be empty.
#
# Those objects are the task of 192 bytes
# and the SPSC channels that serve as future
# of size 256 bytes due to padding by once or twice the cacheline (128-256 bytes total)
#
# To simplify the data structure, we always hand out aligned 256 bytes memory blocks.

# Note, with an allocator when 2 addresses are the same modulo 64K (L1 cache)
# It will cause a L1 cache miss when accessing both in short order
# due to L1 cache aliasing. So when handing out pointers we should randomize
# their order within modulo 64k.
#
# On NUMA, we need to ensure the locality of the pages

import
  ../channels/channels_mpsc_unbounded_batch,
  ../instrumentation/[contracts, loggers],
  ../config,
  ./allocs,
  std/atomics

# Constants (move in config.nim)
# ----------------------------------------------------------------------------------

const WV_MemArenaSize  {.intdefine.} = 1 shl 15 # 2^15 = 32768 bytes = 128 * 256
const WV_MemBlockSize* {.intdefine.} = 256

# Debug
# ----------------------------------------------------------------------------------
# TODO:
# - LLVM Address Sanitizer and memory poisoning (https://clang.llvm.org/docs/AddressSanitizer.html)
# - Valgrind with custom memory pool (http://valgrind.org/docs/manual/mc-manual.html#mc-manual.mempools)

static: assert WV_MemArenaSize.isPowerOfTwo(), "WV_ArenaSize must be a power of 2"
static: assert WV_MemArenaSize > 4096, "WV_ArenaSize must be greater than a OS page (4096 bytes)"

static: assert WV_MemBlockSize.isPowerOfTwo(), "WV_MemBlockSize must be a power of 2"
static: assert WV_MemBlockSize >= 256, "WV_MemBlockSize must be greater or equal to 256 bytes to hold tasks and channels."

template debugMem(body: untyped) =
  when defined(WV_debugMem):
    {.noSideEffect.}:
      body

# Memory Pool types
# ----------------------------------------------------------------------------------

const SizeofMetadata: int = (block:
    var size: int
    size += 272                               # ChannelMpscUnboundedBatch
    size += sizeof(pointer)                   # localFree
    size += sizeof(pointer)                   # free
    size += sizeof(int32)                     # used
    size += sizeof(int32)                     # threadID
    size += sizeof(pointer)                   # prev
    size += sizeof(pointer)                   # next
    size += sizeof(pointer)                   # allocator
    size.roundNextMultipleOf(WV_MemBlockSize) # alignment required
  )
  ## Compile-time sizeof workaround for
  ## https://github.com/nim-lang/Nim/issues/12726
  ## Not ideal: we split metadata in its own subtype
  ## update this const

const MaxBlocks = (WV_MemArenaSize - SizeofMetadata) div WV_MemBlockSize

type
  MemBlock {.union.} = object
    ## Memory block
    ## Linked list node when unused
    ## or raw memory when used.
    # Pointer to MemBlock for intrusive channels.
    # Workaround https://github.com/nim-lang/Nim/issues/12695
    next: Atomic[pointer]
    mem: array[WV_MemBlockSize, byte]

  Metadata = object
    ## Metadata of a thread-local memory arena
    ##
    ## Similar to Microsoft's Mimalloc this memory pool uses
    ## - extreme free list sharding to reduce contention:
    ##   each arena has its free list
    ## - separate thread-local freelists and shared freelist
    ##   to avoid atomics on the fast path
    ## - a dual thread-local freelists design. One is used with
    ##   a fast-path until empty and then costly processing
    ##   that is best amortized over multiple allocations is done
    ##
    ## Similar to Microsoft's Snmalloc and consistent with the project design.
    ## Communications between threads is done via message-passing.
    ##
    # Channel for other Arenas to return the borrowed memory block
    # ⚠️ Consumer thread field must be at the end
    #    to prevent cache-line contention
    #    and save on space (no padding on the next field)
    threadFree {.align: WV_CacheLinePadding.}: ChannelMpscUnboundedBatch[ptr MemBlock]
    # Freed blocks, kept separately to deterministically trigger slow path
    # after an amortized amount of allocation
    localFree: ptr MemBlock
    # Freed blocks, can be allocated on the fast path
    free: ptr MemBlock
    # Number of blocks in use
    used: range[0'i32 .. int32 MaxBlocks] # (WV_MemArenaSize - SizeofMetadata) div WV_MemBlockSize
    # Arena owner
    threadID: Atomic[int32]

  Arena = object
    # TODO: Aligned arenas will create L1 64k aliasing conflicts
    meta {.align: WV_CacheLinePadding.}: Metadata
    # Intrusive queue
    prev, next: ptr Arena
    allocator: ptr TLPoolAllocator
    # Raw memory
    blocks {.align: WV_MemBlockSize.}: array[MaxBlocks, MemBlock]

  TLPoolAllocator* = object
    ## Thread-local pool allocator
    ##
    ## To properly manage exits, thread-local pool allocators
    ## should be kept in an array by the root thread.
    ## They will collect all free memory on exit and release
    ## all the empty arenas.
    ## However if a memory block escaped the exiting thread the corresponding
    ## arena will not be reclaimed and the arena should be assigned to the root thread.
    ##
    ## ⚠️ The pool allocator should be allocated
    ##    on the heap instead of with {.threadvar.}
    ##    if you need to disconnect its lifetime
    ##    from its owning thread.
    first {.align: WV_CacheLinePadding.}: ptr Arena
    last: ptr Arena
    numArenas: range[int32(0) .. high(int32)]
    threadID: int32

# Heuristics
# ----------------------------------------------------------------------------------

const
  MostlyUsedRatio = 8
    ## Beyond 7/8 of its capacity an arena is considered mostly used.
  MaxSlowFrees = 8'i8
    ## In the slow path, up to 8 pages can be considered for release at once.

# Data structures
# ----------------------------------------------------------------------------------

iterator backward(tail: ptr Arena): ptr Arena =
  ## Doubly-linked list backward iterator
  ## Not: we assume that the list is not circular
  ## and terminates via a nil pointer
  var cur = tail
  while not cur.isNil:
    let prev = cur.prev # Arena can be deleted while iterating
    yield cur
    cur = prev

iterator items(head: ptr MemBlock): ptr MemBlock =
  ## Singly-linked list iterator
  preCondition: not head.isNil
  var cur = head
  while true:
    let next = cast[ptr MemBlock](cur.next.load(moRelaxed))
    yield cur
    cur = next
    if cur.isNil:
      break

func prepend(a, b: ptr MemBlock) {.inline.} =
  preCondition: not b.isNil
  preCondition: not a.isNil
  b.next.store(a, moRelaxed)

func append(pool: var TLPoolAllocator, arena: ptr Arena) {.inline.} =
  preCondition: arena.next.isNil

  debugMem:
    log("Pool    0x%.08x - TID %d - append Arena 0x%.08x\n",
      pool.addr, pool.threadID, arena)

  if pool.numArenas == 0:
    ascertain: pool.first.isNil
    ascertain: pool.last.isNil
    pool.first = arena
  else:
    arena.prev = pool.last
    pool.last.next = arena
  pool.last = arena

  pool.numArenas += 1
  arena.allocator = pool.addr

proc newArena(pool: var TLPoolAllocator): ptr Arena =
  ## Reserve memory for a new Arena from the OS
  ## and append it to the allocator

  result = wv_allocAligned(Arena, WV_MemArenaSize)

  debugMem:
    log("Pool    0x%.08x - TID %d - reserved Arena 0x%.08x\n",
      pool.addr, pool.threadID, result)

  result.meta.threadFree.initialize()
  result.meta.localFree = nil
  result.meta.used = 0
  result.meta.threadID.store pool.threadID, moRelaxed

  # Freelist
  result.meta.free = result.blocks[0].addr
  result.blocks[^1].next.store(nil, moRelaxed)
  for i in 0 ..< result.blocks.len - 1:
    result.blocks[i].next.store(result.blocks[i+1].addr, moRelaxed)

  # Pool
  result.prev = nil
  result.next = nil
  pool.append(result)

func getArena(p: pointer): ptr Arena {.inline.} =
  ## Find the arena that owns a memory block
  static: doAssert WV_MemArenaSize.isPowerOfTwo()

  let arenaAddr = cast[ByteAddress](p) and not(WV_MemArenaSize-1)
  result = cast[ptr Arena](arenaAddr)

  # Sanity check to ensure we're in an Arena
  # TODO: LLVM ASAN, poisoning/unpoisoning?
  postCondition: not result.isNil
  postCondition: not result.allocator.isNil
  postCondition: result.meta.used in 0 .. result.blocks.len

# Arena
# ----------------------------------------------------------------------------------
# TODO: metrics

# We assume that "localFree" decrement "used" immediately
# while threadFree are deferred

func isUnused(arena: ptr Arena): bool =
  let pending = arena.meta.threadFree.peek()
  ascertain: pending in 0 .. arena.meta.used
  return arena.meta.used - pending == 0

func isMostlyUsed(arena: ptr Arena): bool =
  ## If more than 7/8 of an Arena is used
  ## it is considered mostly used.
  ## A non-existing arena (nil) is also considered used
  ## (for the head or tail arenas)
  if arena.isNil:
    return true

  const threshold = (arena.blocks.len + 7) div 8
  # Peeking into a channel from a consumer thread
  # will give a lower bound
  result = arena.blocks.len - arena.meta.used + arena.meta.threadFree.peek() <= threshold

func collect(arena: var Arena, force: bool) =
  ## Collect garbage memory in the page
  ## We only move localFree to free when it's O(1)
  ## except on thread teardown

  let beforeCollect = arena.meta.used

  if not arena.meta.localFree.isNil:
    if likely(arena.meta.free.isNil):
      # Fast path
      arena.meta.free = arena.meta.localFree
      arena.meta.localFree = nil
    elif force:
      # Very slow path: only on thread teardown
      for memBlock in arena.meta.localFree:
        arena.meta.free.prepend(memBlock)
      arena.meta.localFree = nil
      debugMem:
        log("Arena   0x%.08x - TID %d - collecting localFree, slow path (reclaimed %d)\n",
          arena.addr, arena.meta.threadID, arena.blocks.len - arena.meta.used)

  debugMem:
    log("Arena   0x%.08x - TID %d - collect, threadFree.peek() %d blocks (%d used or pending)\n",
      arena.addr, arena.meta.threadID.load(moRelaxed), arena.meta.threadFree.peek(), arena.meta.used)

  var first, last: ptr MemBlock
  let count = arena.meta.threadFree.tryRecvBatch(first, last)

  debugMem:
    log("Arena   0x%.08x - TID %d - collect, batched threadFree %d blocks (%d blocks used)\n",
      arena.addr, arena.meta.threadID.load(moRelaxed), count, arena.meta.used - count)

  if count > 0:
    if arena.meta.free.isNil:
      arena.meta.free = first
      last.next.store(nil, moRelaxed)
    else:
      arena.meta.free.prepend(last)
    arena.meta.used -= count

  debugMem:
    log("Arena   0x%.08x - TID %d - collected garbage, reclaimed %d blocks (%d used)\n",
      arena.addr, arena.meta.threadID.load(moRelaxed), beforeCollect - arena.meta.used, arena.meta.used)

func allocBlock(arena: var Arena): ptr MemBlock =
  ## Allocate from a page
  preCondition: not arena.meta.free.isNil
  preCondition: arena.meta.used < arena.blocks.len

  arena.meta.used += 1
  result = arena.meta.free
  # The following acts as prefetching for the block that we are returning as well
  arena.meta.free = cast[ptr MemBlock](result.next.load(moRelaxed))

  postCondition: arena.meta.used in 0 .. arena.blocks.len

# Allocator
# ----------------------------------------------------------------------------------
# TODO: metrics

func release(pool: var TLPoolAllocator, arena: ptr Arena) =
  ## Returns the memory of an arena to the OS
  if pool.first == arena: pool.first = arena.next
  if pool.last == arena: pool.last = arena.prev
  if arena.prev != nil: arena.prev.next = arena.next
  if arena.next != nil: arena.next.prev = arena.prev

  pool.numArenas -= 1

  debugMem:
    log("Pool    0x%.08x - TID %d - returning Arena 0x%.08x to the OS, %d arenas left\n",
      pool.addr, pool.threadID, arena, pool.numArenas)

  wv_freeAligned(arena)

func considerRelease(pool: var TLPoolAllocator, arena: ptr Arena) =
  ## Test if an arena memory should be released to the OS
  debugMem:
    log("Pool    0x%.08x - TID %d - considering Arena 0x%.08x for release, %d arenas in pool\n",
      pool.addr, pool.threadID, arena, pool.numArenas)

  # We don't want to release and then reserve memory too often
  # for example if we just provided a new block and it's returned.
  # As a fast heuristic we check if the arena neighbors are fully used.
  if arena.prev.isMostlyUsed() and arena.next.isMostlyUsed():
    # We probably have the only usable arena in the pool
    # Question? special case to allow the pool to release
    #           the first or last arena when only 2 are left.
    return
  # Other arenas are usable, return memory to the OS
  pool.release(arena)

proc allocSlow(pool: var TLPoolAllocator): ptr MemBlock =
  ## Slow path of allocation
  ## Expensive pool maintenance goes there
  ## and will be amortized over many allocations

  debugMem:
    log("Pool    0x%.08x - TID %d - entering slow maintenance path (%d arenas in pool)\n",
      pool.addr, pool.threadID, pool.numArenas)

  var slowFrees: int8
  # When iterating to find a free block, we iterate in reverse.
  # Note that both mimalloc and snmalloc iterate forward
  #      even though snmalloc used to have a stack strategy:
  #      https://github.com/microsoft/snmalloc/pull/65
  # In our case this is motivated by fork-join parallelism
  # behaving in a stack-like manner (cactus-stack):
  # i.e. the early tasks, especially the root one
  #      will outlive their children.
  for arena in pool.last.backward():
    # 0. Collect freed blocks by us and other threads
    arena[].collect(force = false)
    if not arena.meta.free.isNil:
      # 1.0 If we now have free blocks
      if slowFrees < MaxSlowFrees and arena.isUnused:
        # 1.0.0 Maybe they are complety unused and should be released to the OS
        pool.considerRelease(arena)
        slowFrees += 1
        continue
      else:
        # 1.0.1 If not, let's use the arena
        return arena[].allocBlock()
    # For optimization we might consider removing full arenas from the iteration list

  # All our arenas are full, we need a new one
  let freshArena = pool.newArena()
  return freshArena[].allocBlock()

# Public API
# ----------------------------------------------------------------------------------

proc initialize*(pool: var TLPoolAllocator, threadID: int32) =
  ## Initialize a thread-local memory pool
  ## This automatically reserves one arena
  ## of WV_MemArenaSize (default 32kB) that can
  ## serve fixed size memory block for types
  ## of size up to WV_MemBlockSize (default 256B)
  ##
  ## The memory-pool is thread-safe. Calling ``recycle``
  ## will automatically handle deallocation from any thread.
  ## A thread can have multiple allocators.
  ##
  ## An allocator can ``takeover`` the memory managed by
  ## another allocator in the same thread or by a thread that exited.
  ##
  ## ⚠️ The pool allocator should be allocated
  ##    on the heap instead of with {.threadvar.}
  ##    if you need to disconnect its lifetime
  ##    from its owning thread.

  debugMem:
    log("Pool    0x%.08x - TID %d - initializing\n",
      pool.addr, threadID, pool.numArenas)

  pool.threadID = threadID
  discard pool.newArena()

  postCondition: not pool.first.isNil
  postCondition: not pool.last.isNil
  postCondition: pool.numArenas == 1
  postCondition: pool.first == pool.last
  postCondition: pool.first.meta.threadID.load(moRelaxed) == pool.threadID

proc borrow*(pool: var TLPoolAllocator, T: typedesc): ptr T =
  ## Provides an unused memory block of size
  ## WV_MemBlockSize (256 bytes)
  ##
  ## The object must be properly initialized by the caller.
  ## This is thread-safe, the memory block can be recycled by any thread.
  ##
  ## If the underlying pool runs out-of-memory, it will reserve more from the OS.

  # We try to allocate from the last arena as workload is LIFO-biaised
  # TODO: sizeof Atomics - https://github.com/nim-lang/Nim/issues/12726
  # static: doAssert sizeof(T) <= WV_MemBlockSize,
  #   $T & "is of size " & $sizeof(T) &
  #   ", the maximum object size supported is " &
  #   $WV_MemBlockSize & " bytes (WV_MemBlockSize)"

  if pool.last.meta.free.isNil:
    # Fallback to slow path
    return cast[ptr T](pool.allocSlow())
  else:
    # Fast-path
    return cast[ptr T](pool.last[].allocBlock())

proc recycle*[T](myThreadID: int32, p: ptr T) =
  ## Returns a memory block to its memory pool.
  ##
  ## This is thread-safe, any thread can call it.
  ## It must indicates its ID.
  ## A fast path is used if it's the ID of the borrowing thread,
  ## otherwise a slow path will be used.
  ##
  ## If the thread owning the pool was exited before this
  ## block was returned, the main thread should now
  ## have ownership of the related arenas and can deallocate them.

  # TODO: sink ptr T - parsing bug to raise
  #   similar to https://github.com/nim-lang/Nim/issues/12091
  preCondition: not p.isNil

  let p = cast[ptr MemBlock](p)

  # Find the owning arena
  let arena = p.getArena()

  if myThreadID == arena.meta.threadID.load(moRelaxed):
    # thread-local free
    if arena.meta.localFree.isNil:
      p.next.store(nil, moRelaxed)
      arena.meta.localFree = p
    else:
      arena.meta.localFree.prepend(p)
    arena.meta.used -= 1
    if unlikely(arena.isUnused()):
      # If an arena is unused, we can try releasing it immediately
      arena.allocator[].considerRelease(arena)
  else:
    # remote arena
    let remoteRecycled = arena.meta.threadFree.trySend(p)
    postCondition: remoteRecycled

proc teardown*(pool: var TLPoolAllocator): bool =
  ## Destroy all arenas owned by the allocator.
  ## This is meant to be used before joining threads / thread teardown.
  ##
  ## Returns true if all arenas managed to be deallocated.
  ##
  ## If one or more arenas still have memory blocks in use
  ## they are not deallocated and teardown returns false.
  ##
  ## The ``pool`` is kept in consistent state with regards to
  ## its metadata. Another thread can ``takeover`` the pool resources
  ## with the ``takeover`` function if teardown was unsuccessful.

  debugMem:
    log("Pool    0x%.08x - TID %d - teardown (%d arenas in pool)\n",
      pool.addr, pool.threadID, pool.numArenas)

  for arena in pool.last.backward():
    # Collect freed blocks by us and other threads
    arena[].collect(force = true)
    if arena.isUnused:
      pool.release(arena)

  result = pool.numArenas == 0

  debugMem:
    log("Pool    0x%.08x - TID %d - end teardown (%d arenas left)\n",
      pool.addr, pool.numArenas)

  postCondition:
    if result: pool.first.isNil and pool.last.isNil
    else: not(pool.first.isNil and pool.last.isNil)

proc takeover*(pool: var TLPoolAllocator, target: sink TLPoolAllocator) =
  ## Take ownership of all the memory arenas managed by
  ## the target pool allocator.
  ## If all memory from an arena has been returned by the time.
  ## We release the arena to the OS.
  ##
  ## This must be called when the target allocator original owning thread
  ## has exited.
  ##
  ## The `target` allocator must not be reused.

  debugMem:
    log("Pool    0x%.08x (%d arenas) - TID %d - taking over 0x%.08x (%d arenas, TID %d)\n",
      pool.addr, pool.numArenas, pool.threadID, target.addr, target.numArenas)

  for arena in target.last.backward():
    # Collect all freed blocks, release the arena if we can
    arena[].collect(force = false)
    if arena.isUnused:
      target.release(arena)
    else:
      # Take ownership. We can use relaxed atomics
      # even if there is a race on threadID,
      # the original owner doesn't exist so it will be done
      # via channel
      arena.allocator = pool.addr
      arena.meta.threadID.store pool.threadID, moRelaxed

  # Now we can batch append (should we enqueue instead?)
  # As pool is "active" we assume that at least one arena is allocated
  ascertain: pool.numArenas > 0
  ascertain: target.first.prev.isNil
  ascertain: target.last.next.isNil
  ascertain: pool.first.prev.isNil
  ascertain: pool.last.next.isNil

  target.first.prev = pool.last
  pool.last.next = target.first
  pool.last = target.last
  pool.numArenas += target.numArenas

# Sanity checks and bench
# ----------------------------------------------------------------------------------

assert sizeof(ChannelMpscUnboundedBatch[ptr MemBlock]) == 272,
  "MPSC channel size was " & $sizeof(ChannelMpscUnboundedBatch[ptr MemBlock])

assert sizeof(Arena) == WV_MemArenaSize,
  "The real arena size was " & $sizeof(Arena) &
  " but the asked WV_MemArenaSize was " & $WV_MemArenaSize

when isMainModule:
  import times, strformat, system/ansi_c, math, strutils
  import ../channels/channels_mpsc_unbounded

  # Single-threaded
  # ----------------------------------------------------------------------------------

  const Iters = 250000

  type MyObject = object
    data: array[32, uint64] # 256 byte

  proc benchSingleThreadedPool(NumAllocs: static int) =
    var pointers: ref array[NumAllocs, ptr MyObject]
    new pointers
    let myID = 0'i32

    let start = cpuTime()

    var pool: TLPoolAllocator
    pool.initialize(threadID = myID)

    for i in 0 ..< Iters:
      for j in 0 ..< NumAllocs:
        pointers[j] = pool.borrow(MyObject)
      # Deallocate in mixed order - note that the mempool
      # is optimized for LIFO dealloc.
      for j in countup(0, NumAllocs-1, 2):
        myID.recycle(pointers[j])
      for j in countup(1, NumAllocs-1, 2):
        myID.recycle(pointers[j])

    let stop = cpuTime()
    echo &"Single-threaded: Pool   alloc for {NumAllocs} blocks: {stop-start:.4f} s"

  proc benchSingleThreadedSystem(NumAllocs: static int) =
    var pointers: ref array[NumAllocs, pointer]
    new pointers
    let myID = 0

    let start = cpuTime()

    for i in 0 ..< Iters:
      for j in 0 ..< NumAllocs:
        pointers[j] = c_malloc(csize_t sizeof(MyObject))
      for j in countup(0, NumAllocs-1, 2):
        c_free(pointers[j])
      for j in countup(1, NumAllocs-1, 2):
        c_free(pointers[j])

    let stop = cpuTime()
    echo &"Single-threaded: System alloc for {NumAllocs} blocks: {stop - start:.4f} s"

  # Multi-threaded
  # ----------------------------------------------------------------------------------

  when not compileOption("threads"):
    {.error: "This requires --threads:on compilation flag".}

  template sendLoop[T](chan: var ChannelMpscUnbounded[T],
                       data: sink T,
                       body: untyped): untyped =
    while not chan.trySend(data):
      body

  template recvLoop[T](chan: var ChannelMpscUnbounded[T],
                       data: var T,
                       body: untyped): untyped =
    while not chan.tryRecv(data):
      body

  type
    WorkerKind = enum
      Receiver
      Sender1
      Sender2
      Sender3
      Sender4
      Sender5
      Sender6
      Sender7
      Sender8
      Sender9
      Sender10
      Sender11
      Sender12
      Sender13
      Sender14
      Sender15

    Val = ptr ValObj
    ValObj = object
      next: Atomic[pointer]
      val: int

    ThreadArgs = object
      ID: WorkerKind
      chan: ptr ChannelMpscUnbounded[Val]
      pool: ptr TLPoolAllocator

    AllocKind = enum
      System
      Nim
      Pool

  template genBench(Alloc: untyped, NumVals: static int): untyped =
    const Padding = 10 * NumVals # Pad with a 0 so that iteration 10 of thread 3 is 3010 with 99 max iters


    proc `thread_func Alloc`(args: ThreadArgs) =
      when Alloc == Pool:
        let pool = args.pool
        pool[].initialize(threadID = args.ID.int32)

      template Worker(id: WorkerKind, body: untyped): untyped {.dirty.} =
        if args.ID == id:
          body

      template Worker(id: Slice[WorkerKind], body: untyped): untyped {.dirty.} =
        if args.ID in id:
          body

      template valAlloc(kind: static AllocKind): Val =
        when kind == System:
          cast[Val](c_malloc(csize_t sizeof(ValObj)))
        elif kind == Nim:
          createShared(ValObj)
        else:
          # workaround sizeof atomics
          assert sizeof(ValObj) == 16
          cast[Val](pool[].borrow(array[16, byte]))

      template valFree(kind: static AllocKind, val: Val) =
        when kind == System:
          c_free(val)
        elif kind == Nim:
          freeShared(val)
        else:
          recycle(myThreadID = ord(Receiver), val)

      Worker(Receiver):
        var counts: array[Sender1..Sender15, int]
        for j in 0 ..< 15 * NumVals:
          var val: Val
          args.chan[].recvLoop(val):
            discard
          # log("Receiver got: %d at address 0x%.08x\n", val.val, val)
          let sender = WorkerKind(val.val div Padding)
          let current = counts[sender] + ord(sender) * Padding
          doAssert val.val == current,
            "Incorrect value: " & $val.val &
            ", sender counts was at " & $current
          inc counts[sender]
          valFree(Alloc, val)

        for count in counts:
          doAssert count == NumVals

      Worker(Sender1..Sender15):
        for j in 0 ..< NumVals:
          let val = valAlloc(Alloc)
          val.val = ord(args.ID) * Padding + j

          # const pad = spaces(8)
          # echo pad.repeat(ord(args.ID)), 'S', $ord(args.ID), ": ", val.val

          args.chan[].sendLoop(val):
            discard

    proc `benchMultiThreaded Alloc`() =
      var threads: array[WorkerKind, Thread[ThreadArgs]]
      var pools: ptr array[WorkerKind, TLPoolAllocator]

      let chan = createSharedU(ChannelMpscUnbounded[Val])
      chan[].initialize()

      pools = cast[typeof pools](createSharedU(TLPoolAllocator, pools[].len))

      # Note we also measure thread creation/teardown overhead
      # because doing otherwise is tricky
      let start = epochTime()

      createThread(threads[Receiver], `thread_func Alloc`,
        ThreadArgs(ID: Receiver, chan: chan, pool: pools[Receiver].addr))
      for sender in Sender1..Sender15:
        createThread(threads[sender], `thread_func Alloc`,
          ThreadArgs(ID: sender, chan: chan, pool: pools[sender].addr))

      for worker in WorkerKind:
        joinThread(threads[worker])

      let stop = epochTime()

      echo "Multi-threaded: ", $Alloc, " alloc: ", $round(stop-start, 4), " s"

      freeShared(chan)
      freeShared(pools)

  benchSingleThreadedSystem(100)
  benchSingleThreadedPool(100)

  # Note this is probably a worst case scenario for allocators
  # All producers run out of blocks and allocate some
  # and the consumer needs to return them
  # and then the producers have too much

  # genBench(Nim, NumVals = 10000)
  # benchMultiThreadedNim()

  genBench(System, NumVals = 10000)
  benchMultiThreadedSystem()

  genBench(Pool, NumVals = 10000)
  benchMultiThreadedPool()
