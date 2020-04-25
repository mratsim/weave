# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../instrumentation/[contracts, sanitizers],
  ./allocs

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
    freeFn*: proc(elem: T) {.nimcall, gcsafe.}
    # Adaptative freeing
    count: int
    recentAsk: int
    # "closure" - This points to the proc + env currently registered in the allocator
    #             It is nil-ed on destruction of the lookaside list.
    #
    registeredAt: ptr tuple[onHeartbeat: proc(env: pointer) {.nimcall.}, env: pointer]

func initialize*[T](lal: var LookAsideList[T], freeFn: proc(elem: T) {.nimcall, gcsafe.}) {.inline.} =
  lal.top = nil
  lal.freeFn = freeFn
  lal.count = 0
  lal.recentAsk = 0
  lal.registeredAt = nil

func isEmpty(lal: LookAsideList): bool {.inline.} =
  result = lal.top.isNil

func add*[T](lal: var LookAsideList[T], elem: sink T) {.inline.} =
  preCondition(not elem.isNil)

  elem.next = lal.top
  poisonMemRegion(elem, sizeof(deref(T)))
  lal.top = elem

  lal.count += 1

proc popImpl[T](lal: var LookAsideList[T]): T {.inline.} =
  result = lal.top
  unpoisonMemRegion(result, sizeof(deref(T)))
  lal.top = lal.top.next
  # result.next = nil - we assume it is being zero-ed

  lal.count -= 1

func pop*[T](lal: var LookAsideList[T]): T {.inline.} =
  lal.recentAsk += 1
  if lal.isEmpty:
    return nil

  result = lal.popImpl()

proc delete*[T](lal: var LookAsideList[T]) {.gcsafe.} =
  if not lal.registeredAt.isNil:
    lal.registeredAt.onHeartBeat = nil
    lal.registeredAt.env = nil

  while (let elem = lal.pop(); not elem.isNil):
    lal.freeFn(elem)

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

  # TODO: read papers on buffer size and throughput
  #       Note that the more counters, the more expensive add/pop are
  #       Targeting exponential growth/decay seems a good simple start.
  #       WHich ratio? 1.5, 2, the golden ratio?
  #  - http://www.mit.edu/~modiano/papers/CV_C_116.pdf
  #  - http://gdrro.lip6.fr/sites/default/files/slides_COS2017_prahbu.pdf
  #  - https://link.springer.com/article/10.1023/A:1010837416603
  #  - https://groups.google.com/forum/#!msg/comp.lang.c++.moderated/asH_VojWKJw/Lo51JEmLVboJ

  # On destruction, the lookaside list destroys its pointer
  if lal.isNil: return

  # We want the buffer to be big enough to absorb random "jitter".
  # An exponential growth/decay may have nice properties on random buffer misses (see papers)
  # If we have 3x more than what the buffer was asked for we divided the size by 2
  # so we keep 1.5x-3x required items in the buffer if we are flooded.
  if 3*lal.count <= lal.recentAsk:
    lal.recentAsk = 0
    return

  # Otherwise trigger exponential decay
  let half = lal.count shr 1
  while lal.count > half: # this handles the "1" task edge case (half = 0)
    lal.freeFn(lal[].popImpl())

  lal.recentAsk = 0

when defined(cpp):
  # GCC accepts the normal cast
  proc reinterpret_cast[T, U](input: U): T
    {.importcpp: "reinterpret_cast<'0>(@)".}

proc setCacheMaintenanceEx*[T](hook: var tuple[onHeartbeat: proc(env: pointer){.nimcall.}, env: pointer],
                 lal: var LookAsideList[T]) {.inline.} =
  when defined(cpp):
    hook.onHeartbeat = reinterpret_cast[typeof hook.onHeartbeat, typeof cacheMaintenanceEx[T]](cacheMaintenanceEx[T])
  else:
    hook.onHeartbeat = cast[type hook.onHeartbeat](cacheMaintenanceEx[T])
  hook.env = lal.addr

  lal.registeredAt = hook.addr

# Sanity checks
# ------------------------------------------------------------------------------
# Also tested in prell dequeues

when isMainModule:
  import allocs

  proc customFree[T](p: T) {.gcsafe.}=
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

  when not WV_SanitizeAddr:
    echo x.repr

  delete(x)
