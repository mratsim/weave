# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import typetraits

type
  Pooled*[T] = object
    ## A pooled object wrapper
    ## This behaves like an unique_ptr
    ##   - It cannot be copied only moved
    ##   - It's returned to the pool upon destruction
    base*: ptr T

  ObjectPool*[N: static int, T: object] = object
    ## An object pool of object T and size N
    ## The object pool is thread-local and bounded
    stack: array[N, Pooled[T]]
    remaining: int # stack pointer
    rawMem: ptr array[N, T]

# Object Pool
# ------------------------------------------------------------------------------

proc `=destroy`[N: static int, T](pool: var ObjectPool[N, T]) =
  # No destructors to run per object
  static: assert T.supportsCopyMem
  if not pool.rawMem.isNil:
    dealloc(pool.rawMem)

template registerPool*(PoolSize: static int, T: typedesc): untyped =
  ## Register an object pool of a specific size on each active threads.
  static:
    assert T.supportsCopyMem, "Only trivial objects (no GC, default copy and destructor) are supported in the ObjectPool"

  proc bootstrap(pool: var ObjectPool[PoolSize, T]) =
    pool.rawMem = cast[ptr array[PoolSize, T]](createU(T, PoolSize))
    for i in 0 ..< PoolSize:
      pool.stack[i].base = pool.rawMem[i].addr
    pool.remaining = PoolSize

  var `pool T` {.threadvar.}: ObjectPool[PoolSize, T]
  bootstrap(`pool T`)

  proc getPool*(ObjT: type T): ptr ObjectPool[PoolSize, T] {.inline.} =
    ## Get the thread-local pool that manages ObjectType (size: PoolSize)
    ##
    ## It is intended that there can only be one object pool per type per scope
    `pool T`.addr

func recycle[N: static int, T](pool: ptr ObjectPool[N, T], obj: var Pooled[T]) {.inline.} =
  ## Return a Pooled object to its pool.
  assert pool.remaining < N, "An extra pooled object mysteriously slipped in."
  pool.stack[pool.remaining] = move obj
  pool.remaining += 1

func get*[N: static int, T](pool: ptr ObjectPool[N, T]): Pooled[T] {.inline.} =
  ## Get an object from the pool.
  ## The object must be properly initialized by the caller
  assert pool.remaining > 0, "Object pool depleted."
  pool.remaining -= 1
  result = move pool.stack[pool.remaining]

# Pooled object
# ------------------------------------------------------------------------------

proc `=`[T](dest: var Pooled[T], source: Pooled[T]) {.error: "A pooled object cannot be copied".}
proc `=destroy`[T](x: var Pooled[T]) =
  T.getPool().recycle(x)

# Sanity checks
# ------------------------------------------------------------------------------

when isMainModule:
  type Foo = object
    x: int

  registerPool(10, Foo)

  let pool = getPool(Foo)

  proc foo() =
    let p = pool.get()

  proc main() =
    for x in 0 ..< 20:
      foo()

  main()
