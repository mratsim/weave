# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/atomics, std/typetraits

const CacheLineSize {.intdefine.} = 64
  ## True on most machines
  ## Notably false on Samsung phones

type
  ChannelShmSpscBounded*[Capacity: static int, T] = object
    ## Wait-free bounded single-producer single-consumer channel
    ## Properties:
    ##   - wait-free
    ##   - supports weak memory models
    ##   - no modulo operations
    ##   - memory-efficient: buffer the size of the capacity
    ##   - each field is guaranteed on it's own cache line
    ##     even if multiple channels are stored in a contiguous container
    ##
    ## At the moment, only trivial objects can be received or sent
    ## (no GC, can be copied and no custom destructor)
    # TODO: Nim alignment pragma - https://github.com/nim-lang/Nim/pull/11077
    pad0: array[CacheLineSize-sizeof(int), byte]
    head: Atomic[int]
    pad1: array[CacheLineSize-sizeof(int), byte]
    tail: Atomic[int]
    pad2: array[CacheLineSize-sizeof(int), byte]
    buffer: ptr array[Capacity, T]

proc `=`[Capacity, T](
    dest: var ChannelShmSpscBounded[Capacity, T],
    source: ChannelShmSpscBounded[Capacity, T]
  ) {.error: "A channel cannot be copied".}

proc newChannel*(
       ChannelType: type ChannelShmSpscBounded,
       Capacity: static int,
       T: typedesc
     ): ChannelShmSpscBounded[Capacity, T] {.noInit.} =
  ## Creates a new Shared Memory Single Producer Single Consumer Bounded channel

  # No init, we don't need to zero-mem the padding
  # `createU` is thread-local allocation.
  # No risk of false-sharing

  static: assert T.supportsCopyMem
  assert cast[ByteAddress](result.tail.addr) -
    cast[ByteAddress](result.head.addr) >= CacheLineSize

  result.head.store(0, moRelaxed)
  result.tail.store(0, moRelaxed)
  result.buffer = cast[ptr array[Capacity, T]](createU(T, Capacity))

proc `=destroy`[N: static int, T](chan: var ChannelShmSpscBounded[N, T]) =
  static: assert T.supportsCopyMem # no custom destructors or ref objects
  if not chan.buffer.isNil:
    dealloc(chan.buffer)

# Sanity checks
# ------------------------------------------------------------------------------

when isMainModule:
  import ../memory/object_pools

  type Foo = object
    x: int

  var pool{.threadvar.}: ObjectPool[100, ChannelShmSpscBounded[10, Foo]]
  pool.associate()

  pool.initialize()

  proc foo() =
    let p = pool.get()

  proc main() =
    for x in 0 ..< 20:
      foo()

  main()
