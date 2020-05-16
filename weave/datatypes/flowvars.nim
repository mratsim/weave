# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../cross_thread_com/channels_spsc_single,
  ../memory/[allocs, memory_pools],
  ../instrumentation/contracts,
  ../config, ../contexts,
  std/os

type
  LazyChannel* {.union.} = object
    chan*: ptr ChannelSPSCSingle
    buf*: array[sizeof(pointer), byte] # for now only support pointers

  LazyFlowVar* = object
    # No generics allowed at the moment
    # has converting stack lazy futures to heap is done
    # deep in the runtime with no access to type information.
    hasChannel*: bool
    isReady*: bool
    lazy*: LazyChannel

  Flowvar*[T] = object
    ## A Flowvar is a placeholder for a future result that may be computed in parallel
    # Flowvar are optimized when containing a ptr type.
    # They take less size in memory by testing isNil
    # instead of having an extra atomic bool
    # They also use type-erasure to avoid having duplicate code
    # due to generic monomorphization.
    #
    # A lazy flowvar has optimization to allocate on the heap only when required

    # TODO: we can probably default to LazyFlowvar for up to 32 bytes
    #       and fallback to eager futures otherwise.
    #       The only place that doesn't statically know if we have a Lazy or Eager flowvar
    #       is the "convertLazyFlowvar" but it is called seldomly (whole point of lazyness).
    #       but we now carry the type size in the task.
    #       Also a side benefit is LazyFlowvar for FlowvarNode requires 3 allocations,
    #       while eager requires 2.
    when defined(WV_LazyFlowvar):
      lfv*: ptr LazyFlowVar # usually alloca allocated
    else:
      chan: ptr ChannelSPSCSingle

  FlowvarNode* = ptr object
    # LinkedList of flowvars
    # Must be type erased as there is no type
    # information within the runtime

    # TODO: Can we avoid the 3 allocations for lazy flowvars?

    next*: FlowvarNode
    when defined(WV_LazyFlowvar):
      lfv*: ptr LazyFlowVar
    else:
      chan*: ptr ChannelSPSCSingle

func isSpawned*(fv: Flowvar): bool {.inline.} =
  ## Returns true if a flowvar is spawned
  ## This may be useful for recursive algorithms that
  ## may or may not spawn a flowvar depending on a condition.
  ## This is similar to Option or Maybe types
  when defined(WV_LazyFlowVar):
    return not fv.lfv.isNil
  else:
    return not fv.chan.isNil

EagerFV:
  proc recycleChannel*(fv: Flowvar) {.inline.} =
    recycle(fv.chan)

  proc newFlowVar*(pool: var TLPoolAllocator, T: typedesc): Flowvar[T] {.inline.} =
    result.chan = pool.borrow(typeof result.chan[])
    result.chan[].initialize(sizeof(T))

  proc readyWith*[T](fv: Flowvar[T], childResult: T) {.inline.} =
    ## Send the Flowvar result from the child thread processing the task
    ## to its parent thread.
    let resultSent {.used.} = fv.chan[].trySend(childResult)
    postCondition: resultSent

  template tryComplete*[T](fv: Flowvar, parentResult: var T): bool =
    fv.chan[].tryRecv(parentResult)

  func isReady*[T](fv: Flowvar[T]): bool {.inline.} =
    ## Returns true if the result of a Flowvar is ready.
    ## In that case `sync` will not block.
    ## Otherwise the current will block to help on all the pending tasks
    ## until the Flowvar is ready.
    not fv.chan[].isEmpty()

  func cleanup*(fv: Flowvar) {.inline.} =
    ## Cleanup  after forcing a future
    recycleChannel(fv)

LazyFV:
  proc recycleChannel*(fv: Flowvar) {.inline.} =
    recycle(fv.lfv.lazy.chan)

  # Templates everywhere as we use alloca
  template newFlowVar*(pool: TLPoolAllocator, T: typedesc): Flowvar[T] =
    var fv = cast[Flowvar[T]](alloca(LazyFlowVar))
    fv.lfv.lazy.chan = nil
    fv.lfv.hasChannel = false
    fv.lfv.isReady = false
    fv

  template readyWith*[T](fv: Flowvar[T], childResult: T) =
    if not fv.lfv.hasChannel:
      # TODO: buffer the size of T
      static: doAssert sizeof(childResult) <= sizeof(fv.lfv.lazy.buf)
      cast[ptr T](fv.lfv.lazy.buf.addr)[] = childResult
      fv.lfv.isReady = true
    else:
      ascertain: not fv.lfv.lazy.chan.isNil
      discard fv.lfv.lazy.chan[].trySend(childResult)

  template tryComplete*[T](fv: Flowvar, parentResult: var T): bool =
    if fv.lfv.hasChannel:
      ascertain: not fv.lfv.lazy.chan.isNil
      fv.lfv.lazy.chan[].tryRecv(parentResult)
    else:
      fv.lfv.isReady

  func isReady*[T](fv: Flowvar[T]): bool {.inline.} =
    ## Returns true if the result of a Flowvar is ready.
    ## In that case `sync` will not block.
    ## Otherwise the current will block to help on all the pending tasks
    ## until the Flowvar is ready.
    if not fv.lfv.hasChannel:
      fv.lfv.isReady
    else:
      not fv.lfv.lazy.chan[].isEmpty()

  import sync_types

  proc convertLazyFlowvar*(task: Task) {.inline.}=
    # Allocate the lazy flowvar channel on the heap to extend its lifetime
    # Its lifetime exceed the lifetime of the task
    # hence why the lazy flowvar itself is on the stack
    var lfv = cast[ptr LazyFlowvar](task.data.addr)[]
    if not lfv.hasChannel:
      lfv.hasChannel = true
      # TODO, support bigger than pointer size
      lfv.lazy.chan = myMemPool().borrow(ChannelSPSCSingle)
      lfv.lazy.chan[].initialize(itemsize = task.futureSize)
      incCounter(futuresConverted)

  proc batchConvertLazyFlowvar*(task: Task) =
    var task = task
    while not task.isNil:
      if task.hasFuture:
        convertLazyFlowvar(task)
      task = task.next

  func cleanup*[T](fv: Flowvar[T]) {.inline.} =
    ## Cleanup  after forcing a future
    if not fv.lfv.hasChannel:
      ascertain: fv.lfv.isReady
    else:
      ascertain: not fv.lfv.lazy.chan.isNil
      recycleChannel(fv)

# Reductions
# ----------------------------------------------------

proc newFlowvarNode*(itemSize: uint8): FlowvarNode =
  ## Create a linked list of flowvars
  # Lazy flowvars unfortunately are allocated on the heap
  # Can we do better?
  preCondition: itemSize.int <= WV_MemBlockSize - sizeof(deref(FlowvarNode))
  result = myMemPool().borrow(deref(FlowvarNode))
  LazyFV: # 3 alloc total
    result.lfv = myMemPool().borrow(LazyFlowVar)
    result.lfv.lazy.chan = myMemPool().borrow(ChannelSPSCSingle)
    result.lfv.lazy.chan[].initialize(itemSize)
    result.lfv.hasChannel = true
    result.lfv.isReady = false
    incCounter(futuresConverted)
  EagerFV: # 2 alloc total
    result.chan = myMemPool().borrow(ChannelSPSCSingle)
    result.chan[].initialize(itemSize)

proc recycleFVN*(fvNode: sink FlowvarNode) {.inline.} =
  ## Deletes a flowvar node
  ## This assumes that the channel was already recycled
  ## by a "sync"/"forceComplete"
  LazyFV:
    recycle(fvNode.lfv)
  recycle(fvNode)

# TODO destructors for automatic management
#      of the user-visible flowvars

# Foreign threads interop
# ----------------------------------------------------

type Pending*[T] = object
  ## A Pending[T] is a placeholder for the
  ## future result of type T for a job
  ## submitted to Weave for parallel execution.
  # For implementation this is just a distinct type
  # from Flowvars to ensure proper usage
  fv: Flowvar[T]

func isSubmitted*[T](p: Pending[T]): bool {.inline.} =
  ## Returns true if a job has been submitted and we have a result pending
  ## This may be useful for recursive algorithms that
  ## may or may not submit a job depending on a condition.
  ## This is similar to Option or Maybe types
  p.fv.isSpawned

template newPending*(pool: var TLPoolAllocator, T: typedesc): Pending[T] =
  Pending[T](fv: newFlowVar(pool, T))

func isReady*[T](p: Pending[T]): bool {.inline.} =
  ## Returns true if the pending result is ready.
  ## In that case `settle` will not block.
  ## Otherwise the current thread will block.
  p.fv.isReady

func readyWith*[T](p: Pending[T], childResult: T) {.inline.} =
  ## Sends the Pending result from the child thread processing the task
  ## to its parent thread.
  p.fv.readyWith(childResult)

proc waitFor*[T](p: Pending[T]): T {.inline.} =
  ## Wait for a pending value
  ## This blocks the thread until the value is ready
  ## and then returns it.
  preCondition: onSubmitterThread

  var backoff = 1
  while not p.isReady:
    sleep(backoff)
    backoff *= 2
    if backoff > 16:
      backoff = 16

  let ok = p.fv.tryComplete(result)
  ascertain: ok
  cleanup(p.fv)
