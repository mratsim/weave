# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/typetraits, ../instrumentation/contracts

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
  if not T.supportsCopyMem():
    # T has custom destructors or ref objects
    for i in 0 ..< N:
      `=destroy`(pool.rawMem[i])
  if not pool.rawMem.isNil:
    dealloc(pool.rawMem)

proc initialize*[N: static int, T](pool: var ObjectPool[N, T]) =
  ## Initialize an object pool
  ## - Reserve raw memory
  ## - Create pooled objects
  ##
  ## Important: pool objects are created uninitialized.
  ##            Make sure you properly initialize them before use.
  pool.rawMem = cast[ptr array[N, T]](createU(T, N))
  for i in 0 ..< N:
    pool.stack[i].base = pool.rawMem[i].addr
  pool.remaining = N

func recycle[N: static int, T](pool: var ObjectPool[N, T], obj: var Pooled[T]) {.inline.} =
  ## Return a Pooled object to its pool.
  preCondition:
    pool.remaining < N

  pool.stack[pool.remaining] = move obj
  pool.remaining += 1

func get*[N: static int, T](pool: var ObjectPool[N, T]): Pooled[T] {.inline.} =
  ## Get an object from the pool.
  ## The object must be properly initialized by the caller
  preCondition:
    pool.remaining > 0

  pool.remaining -= 1
  result = move pool.stack[pool.remaining]

template associate*[N: static int, T](pool: var ObjectPool[N, T]): untyped =
  ## Bind the object type T to the input pool in the current scope
  proc getPool(ObjT: type T): var ObjectPool[N, T] {.inline.} =
    ## Get the thread-local pool that manages ObjectType (size: T)
    ##
    ## It is intended that there can only be one object pool per type per scope
    pool

# Pooled object
# ------------------------------------------------------------------------------

proc `=`[T](dest: var Pooled[T], source: Pooled[T]) {.error: "A pooled object cannot be copied".}
proc `=destroy`[T](x: var Pooled[T]) =
  mixin getPool
  when not compiles(T.getPool()):
    {.fatal: "The object pool for type \"" & $T & "\" was not associated.".}

  T.getPool().recycle(x)

# Sanity checks
# ------------------------------------------------------------------------------

when isMainModule:
  type Foo = object
    x: int

  var pool{.threadvar.}: ObjectPool[10, Foo]
  pool.associate()

  pool.initialize()

  proc foo() =
    let p = pool.get()

  proc main() =
    for x in 0 ..< 20:
      foo()

  main()
