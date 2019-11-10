# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/typetraits,
  ../static_config,
  ../instrumentation/contracts

type
  Persistack*[N: static int8, T: object] = object
    ## A persistack is a bounded stack that ensures
    ## that the underlying memory is valid throughout
    ## the lifetime of the stack.
    ##
    ## The underlying objects are created on the shared heap.
    ##
    ## The objects must be padded or aligned to ensure
    ## that there is no false-sharing/cache thrashing/cache ping-pong.
    ## I.e. the end of an object should not be in the same
    ##      cache-line as the start of the next objects.
    ##
    ## The use-case is, in a multithreading context,
    ## to allow a thread to:
    ## - create multiple channels,
    ## - send a pointer to them in messages,
    ##   so that other threads have an address to reply to
    ##   similar to a mailbox.
    ##
    ## The original sender needs to keep access to those mailboxes.
    ##
    ## Note that a Persistack assumes that receiver threads
    ## are nicely behaved and don't escape with that mailbox.
    ##
    ## Naming:
    ## - It's not exactly a stack because it owns memory and
    ##   access to all memory allocated is always valid
    ## - It's not an object ps because the resource is shared
    ##   and it's not returned to the ps after destruction
    ##   it's never destroyed
    ## So I guess I'm free to pick a name?

    # Workers are organized in a binary tree.
    # Parents directly enqueue special actions like shutting down.
    # So persistacks are in a global array
    # and we need to avoid cache line conflict between workers
    pad: array[PicassoCacheLineSize - N*sizeof(ptr T) - sizeof(pointer) - sizeof(int8), byte]
    stack: array[N, ptr T]
    rawMem: ptr array[N, T]
    len*: int8

# Persistack
# ------------------------------------------------------------------------------

proc `=destroy`[N: static int8, T](ps: var Persistack[N, T]) =
  if not T.supportsCopyMem():
    # T has custom destructors or ref objects
    for i in 0 ..< N:
      `=destroy`(ps.rawMem[i])
  if not ps.rawMem.isNil:
    dealloc(ps.rawMem)

proc initialize*[N: static int8, T](ps: var Persistack[N, T]) =
  ## Reserve raw memory and setup the persistack
  ##
  ## Important: The objects themselves are created uninitialized.
  ##            Make sure you properly initialize them before use.
  ps.rawMem = cast[ptr array[N, T]](createU(T, N))
  for i in 0 ..< N:
    ps.stack[i] = ps.rawMem[i].addr
  ps.len = N

func borrow*[N: static int8, T](ps: var Persistack[N, T]): ptr T {.inline.} =
  ## Provides a reference from the persistack
  ## This reference will not be provided anymore
  ## until it is recycled.
  ##
  ## The object must be properly initialized by the caller.
  preCondition:
    ps.len > 0

  ps.len -= 1
  result = move ps.stack[ps.len]

func recycle*[N: static int8, T](ps: var Persistack[N, T], reference: sink(ptr T)) {.inline.} =
  ## Returns a reference to the persistack.
  preCondition:
    ps.len < N

  `=sink`(ps.stack[ps.len], reference)
  ps.len += 1

func nowAvailable*[N: static int8, T](ps: var Persistack[N, T], index: SomeInteger) {.inline.} =
  ## Object at `index` is available again (but was not returned directly)
  preCondition:
    ps.len < N

  ps.stack[ps.len] = ps.rawMem[index].addr
  ps.len += 1

func access*[N: static int8, T](ps: Persistack[N, T], index: SomeInteger): var T {.inline.} =
  ## Access the object at `index`.
  preCondition:
    index < N
  ps.rawMem[index]

# Sanity checks
# ------------------------------------------------------------------------------

when isMainModule:
  type Foo = object
    x: int

  var ps{.threadvar.}: Persistack[10'i8, Foo]

  ps.initialize()

  proc foo() =
    let p = ps.borrow()
    ps.recycle(p)

  proc main() =
    for x in 0 ..< 20:
      foo()
    echo "[SUCCESS]"

  main()
