# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import locks

const CacheLineSize {.intdefine.} = 64
  ## True on most machines
  ## Notably false on Samsung phones
  ## We might need to use 2x CacheLine to avoid prefetching cache conflict

type
  ChannelShmMpscBoundedLock*[T] = object
    ## Lock-based multi-producer single-consumer channel
    ##
    ## Properties:
    ##   - Lock-based
    ##   - no modulo operations
    ##   - memory-efficient: buffer the size of the capacity
    ##   - Padded to avoid false sharing
    ##   - No extra indirection to access the item
    ##   - Linearizable (?)
    ##
    ## Usage:
    ##   When producer wait/sleep is not an issue as they don't have
    ##   useful work to do.
    ##
    ## At the moment, only trivial objects can be received or sent
    ## (no GC, can be copied and no custom destructor)
    ##
    ## The content of the channel is not destroyed upon channel destruction
    ## Destroying a channel containing ptr object will not deallocate them
    pad0: array[CacheLineSize - sizeof(int), byte]
    capacity: int
    buffer: ptr UncheckedArray[T]
    pad1: array[CacheLineSize - sizeof(int), byte]
    front: int
    pad2: array[CacheLineSize - sizeof(int) - sizeof(Lock), byte]
    backLock: Lock
    back: int

    # To differentiate between full and empty case
    # we don't rollover the front and back indices to 0
    # when they reach capacity.
    # But only when they reach 2*capacity.
    # When they are the same the queue is empty.
    # When the difference is capacity, the queue is full.

  # Private aliases
  Channel[T] = ChannelShmSpscBounded[T]

proc `=`[T](
    dest: var Channel[T],
    source: Channel[T]
  ) {.error: "A channel cannot be copied".}

proc `=destroy`[T](chan: var Channel[T]) {.inline.} =
  static: assert T.supportsCopyMem # no custom destructors or ref objects
  if not chan.buffer.isNil:
    dealloc(chan.buffer)

func clear*(chan: var Channel) {.inline.} =
  ## Reinitialize the data in the channel
  ## We assume the buffer was already initialized.
  ##
  ## This is not threadsafe
  assert not chan.buffer.isNil
  chan.front.store(0, moRelaxed)
  chan.back.store(0, moRelaxed)

func initialize*[T](chan: var Channel[T], capacity: Positive) =
  ## Creates a new Shared Memory Multi-Producer Producer Single Consumer Bounded channel

  # No init, we don't need to zero-mem the padding
  # `createU` is thread-local allocation.
  # No risk of false-sharing

  static: assert T.supportsCopyMem
  assert cast[ByteAddress](chan.back.addr) -
    cast[ByteAddress](chan.front.addr) >= CacheLineSize

  chan.buffer = cast[ptr UncheckedArray[T]](createU(T, capacity))
  chan.clear()
