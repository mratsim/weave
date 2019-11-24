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
  ../channels/channels_mpsc_unbounded,
  ../config,
  std/atomics

# Helpers
# ----------------------------------------------------------------------------------

proc isPowerOfTwo(n: int): bool =
  (n and (n - 1)) == 0

func roundNextMultipleOf(x: Natural, n: static Natural): int {.inline.} =
  ## Round the input to the next multiple of "n"
  when (n and (n - 1)) == 0:
    # n is a power of 2. (If compiler cannot prove that x>0 it does not make the optim)
    result = (x + n - 1) and not(n - 1)
  else:
    result = ((x + n - 1) div n) * n

# Constants (move in config.nim)
# ----------------------------------------------------------------------------------

const WV_MemArenaSize {.intdefine.} = 1 shl 15 # 2^15 = 32768 bytes = 128 * 256
const WV_MemBlockSize {.intdefine.} = 256

static: assert WV_MemArenaSize.isPowerOfTwo(), "WV_ArenaSize must be a power of 2"
static: assert WV_MemArenaSize > 4096, "WV_ArenaSize must be greater than a OS page (4096 bytes)"

static: assert WV_MemBlockSize.isPowerOfTwo(), "WV_MemBlockSize must be a power of 2"
static: assert WV_MemBlockSize >= 256, "WV_MemBlockSize must be greater or equal to 256 bytes to hold tasks and channels."

# Memory Pool types
# ----------------------------------------------------------------------------------

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
    threadFree {.align: WV_CacheLinePadding.}: ChannelMpscUnbounded[ptr MemBlock]
    # Freed blocks, kept separately to deterministically trigger slow path
    # after an amortized amount of allocation
    localFree: ptr MemBlock
    # Freed blocks, can be allocated on the fast path
    free: ptr MemBlock
    # Number of blocks in use
    used: int32

const SizeofMetadata: int = (block:
    var size: int
    size += 288                               # ChannelMpscUnbounded
    size += sizeof(ptr MemBlock)              # localFree
    size += sizeof(ptr MemBlock)              # free
    size += sizeof(int)                       # used
    size.roundNextMultipleOf(WV_MemBlockSize) # alignment required
  )
  ## Compile-time sizeof workaround for
  ## https://github.com/nim-lang/Nim/issues/12726

type
  Arena = object
    meta {.align: WV_CacheLinePadding.}: Metadata
    blocks {.align: WV_MemBlockSize.}: array[(WV_MemArenaSize - SizeofMetadata) div WV_MemBlockSize, MemBlock]

# Sanity checks
# ----------------------------------------------------------------------------------

when isMainModule:
  # runtime size of Arena is expected
  doAssert sizeof(Arena) == WV_MemArenaSize
