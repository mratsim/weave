# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../instrumentation/contracts

type
  IntrusiveStackable* = concept x, type T
    x is ptr
    x.next is T

  LookAsideList*[T: IntrusiveStackable] = object
    ## LookAside List for ptr objects
    ## Those objects should implement a "next" field
    ## that will be used for ordering by the LookAsideList
    ##
    ## LookAsideList takes ownership of the pointer object pushed into it.
    ## It expects elements to be allocated via a thread-safe allocator.
    ##
    ## Ideally the allocator provides a "heartbeat", i.e. when it's a good time
    ## to performance expensive but amortized operations, the lookaside list
    ## will hook into that heartbeat to perform its own.
    ##
    ## Otherwise the LookAsideList doesn't return back memory, the usage might grow
    ## on long-running processes with unbalanced producer-consumer threads
    ## with sides always being depleted and caching without bounds.

    # A note on cactus stacks:
    #       This data-structure is used for caching tasks and reuse them without
    #       stressing the Nim/system allocator or the memory pool
    #
    #       A cactus stack happens when a task (for example fibonacci)
    #       spawns N stacks, which then spawns M tasks.
    #       Then the stacks of grandchildren are:
    #         - Root 1 -> 11 -> 111
    #         - Root 1 -> 11 -> 112
    #         - Root 1 -> 12 -> 121
    #         - Root 1 -> 12 -> 122
    #       and pop-ing from those stacks doesn't translate to a linear memory pop.
    #       See memory.md in memory folder

    # TODO: ideally, most of the proc are type-erased to avoid monomorphization
    #       ballooning our code size. But we only use this with the task type so ...

    # Stack pointer
    top: T
    # Mempool doesn't provide the proper free yet
    # freeFn*: proc(threadID: int32, t: T) {.nimcall, gcsafe.}
    # threadID*: int32
    # # Adaptative freeing
    # count: int32
    # recentIn: int32
    # recentOut: int32
    # recentCacheMisses: int32
    # recycleHalf: bool
    # # "closure" - This points to the proc + env currently registered in the allocator
    # #             It is nil-ed on destruction of the lookaside list.
    # #
    # registeredAt: ptr tuple[onHeartbeat: proc(env: pointer) {.nimcall.}, env: pointer]

func initialize*[T](lal: var LookAsideList[T], tID: int32, freeFn: proc(threadID: int32, t: T) {.nimcall, gcsafe.}) =
  ## We assume the lookaside lists is zero-init when the thread-local context is allocated
  # lal.freeFn = freeFn
  # lal.threadID = tID

func isEmpty(lal: LookAsideList): bool {.inline.} =
  result = lal.top.isNil

func add*[T](lal: var LookAsideList[T], elem: sink T) {.inline.} =
  preCondition(not elem.isNil)

  elem.next = lal.top
  lal.top = elem

  # lal.recentIn += 1
  # lal.count += 1

proc popImpl[T](lal: var LookAsideList[T]): T {.inline.} =
  result = lal.top
  lal.top = lal.top.next
  # result.next = nil - we assume it is being zero-ed

  # lal.count -= 1

func pop*[T](lal: var LookAsideList[T]): T {.inline.} =
  if lal.isEmpty:
    # lal.recentCacheMisses += 1
    return nil

  result = lal.popImpl()

  # lal.recentOut += 1

proc delete*[T](lal: var LookAsideList[T]) {.gcsafe.}=
  if not lal.registeredAt.isNil:
    lal.registeredAt.onHeartBeat = nil
    lal.registeredAt.env = nil

  while (let elem = lal.pop(); not elem.isNil):
    lal.freeFn(lal.threadID, elem)

proc evict[T](lal: ptr LookAsideList[T]) =
  ## Evict objects according to the current policy
  if not lal.recycleHalf:
    lal.freeFn(lal.threadID, lal[].popImpl())
  else:
    let half = lal.count shr 1
    while lal.count > half: # this handle the "1" task edge case (half = 0)
      lal.freeFn(lal.threadID, lal[].popImpl())

  lal.recentIn = 0
  lal.recentOut = 0
  lal.recentCacheMisses = 0

proc cacheMaintenanceEx[T](lal: ptr LookAsideList[T]) =
  ## Expensive memory maintenance,
  ## that should be amortized other many allocations.
  ## This should be triggered automatically on allocator heartbeat
  ##
  ## ⚠️ This is not thread-safe! The thread executing this should
  ##    have exclusive access to both the lookaside list and the allocator
  ##    providing the heartbeat
  ##
  ## Note: we assume that the underlying allocator triggers
  ##       maintenance on **allocation**.
  ##       As this deallocates, we could have an avalanche effect with many
  ##       deallocations triggering other heartbeats in cascade.

  # On destruction, the lookaside list destroys its pointer
  if lal.isNil: return

  # If we have no more objects or had a cache miss maybe we were too aggressive
  if lal.recentCacheMisses > 0 or lal.top.isNil:
    lal.recentIn = 0
    lal.recentOut = 0
    lal.recycleHalf = false
    return

  # If we allocated no objects, continue decaying the pool at the previous rate
  if lal.recentOut == 0:
    lal.evict()
    return

  # Otherwise we take the ratio of in/out and if it's bigger than 2,
  # we trigger exponential decay
  let ratio = lal.recentIn.float32 / lal.recentOut.float32
  lal.recycleHalf = ratio > 2.0f
  lal.evict()

proc setCacheMaintenanceEx*[T](hook: var tuple[onHeartbeat: proc(env: pointer){.nimcall.}, env: pointer],
                 lal: var LookAsideList[T]) {.inline.} =
  hook.onHeartbeat = cast[proc(env: pointer) {.nimcall.}](cacheMaintenanceEx[T])
  hook.env = lal.addr

  lal.registeredAt = hook.addr

# Sanity checks
# ------------------------------------------------------------------------------
# Also tested in prell dequeues

when isMainModule:
  import allocs

  proc customFree[T](threadID: int32, p: T) =
    wv_free(p)

  type
    Node = ptr object
      payload: int
      next: Node

  let
    a = wv_allocPtr(Node)
    b = wv_allocPtr(Node)
    c = wv_allocPtr(Node)
    d = wv_allocPtr(Node)

  a.payload = 10
  b.payload = 20
  c.payload = 30
  d.payload = 40

  var x: LookAsideList[Node]
  x.freeFn = customFree

  x.add a
  x.add b
  x.add c
  x.add d

  echo x.repr

  # Nim will run destructors
