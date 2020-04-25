# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/atomics,
  ../instrumentation/contracts

# Scoped barrier
# ----------------------------------------------------------------------------------

# A scoped barrier allows detecting if there are child, grandchild or descendant tasks
# still running so that a thread can wait for nested spawns.
#
# This solves the following problem:
#
# parallelFor i in 0 ..< M:
#   awaitable: loopI
#   parallelFor j in 0 ..< M:
#     awaitable: loopJ
#     discard
#
# Here, the loop i will add all the parallel tasks for loop j to the task queue
# and continue on. Even if we await loopI, the task was really to just create the loopJ,
# but the loop itself might still be pending in the task queue
#
# We could instead await loopJ before going to the next i iteration but that
# restrict the parallelism exposed.
#
# Alternatively we could use `syncRoot` after those statements but that means
# that it cannot be called from parallel code.
#
# In short:
# - the scoped barrier should prevent a thread from continuing while any descendant task
#   is still running.
# - it should be composable and parallel constructs need not to worry about its presence
#   in spawn functions.
# - the enclosed scope should be able to expose all parallelism opportunities
#   in particular nested parallel for regions.

type
  ScopedBarrier* = object
    ## A scoped barrier allows detecting if there are child, grandchild or descendant tasks
    ## still running so that a thread can wait for nested spawns.
    ##
    ## ScopedBarriers can be nested and work like a stack.
    ## Only one can be active for a given thread for a given code section.
    ##
    ## They can be allocated on the stack given that a scoped barrier can not be exited
    ## before all the descendant tasks exited and so the descendants cannot escape,
    ## i.e. they have a pointer to their scope which is always valid.
    ##
    ## This means that in case of nested scopes, only the inner scope needs to track its descendants.
    descendants: Atomic[int]

# Note: If one is defined, the other destructors proc are not implictly create inline
#       even if trivial

proc `=`*(dst: var ScopedBarrier, src: ScopedBarrier) {.error: "A scoped barrier cannot be copied.".}

proc `=sink`*(dst: var ScopedBarrier, src: ScopedBarrier) {.inline.} =
  # Nim doesn't respect noinit and tries to zeroMem then move the type
  {.warning: "Moving a shared resource (an atomic type).".}
  system.`=sink`(dst.descendants, src.descendants)

proc `=destroy`*(sb: var ScopedBarrier) {.inline.}=
  preCondition: sb.descendants.load(moRelaxed) == 0
  # system.`=destroy`(sb.descendants)

proc initialize*(scopedBarrier: var ScopedBarrier) {.inline.} =
  ## Initialize a scoped barrier
  scopedBarrier.descendants.store(0, moRelaxed)

proc registerDescendant*(scopedBarrier: ptr ScopedBarrier) {.inline.} =
  ## Register a descendant task to the scoped barrier
  ## Important: the thread creating the task must register the descendant
  ## before handing them over to the runtime.
  ## This way, if the end of scope is reached and we have 0 descendant it means that
  ## - either no task was created in the scope
  ## - tasks were created, but descendants increment/decrement cannot reach 0 before all descendants actually exited
  if not scopedBarrier.isNil:
    preCondition: scopedBarrier.descendants.load(moAcquire) >= 0
    discard scopedBarrier.descendants.fetchAdd(1, moRelaxed)
    postCondition: scopedBarrier.descendants.load(moAcquire) >= 1

proc unlistDescendant*(scopedBarrier: ptr ScopedBarrier) {.inline.} =
  ## Unlist a descendant task from the scoped barrier.
  ## Important: if that task spawned new tasks, it is fine even if those grandchild tasks
  ## are still running, however they must have been registered to the scoped barrier toa void race conditions.
  if not scopedBarrier.isNil:
    preCondition: scopedBarrier.descendants.load(moAcquire) >= 1
    fence(moRelease)
    discard scopedBarrier.descendants.fetchSub(1, moRelaxed)
    preCondition: scopedBarrier.descendants.load(moAcquire) >= 0

proc hasDescendantTasks*(scopedBarrier: var ScopedBarrier): bool {.inline.} =
  ## Returns true if a scoped barrier has at least a descendant task.
  ## This should only be called from the thread that created the scoped barrier.
  preCondition: scopedBarrier.descendants.load(moAcquire) >= 0
  result = scopedBarrier.descendants.load(moRelaxed) == 0
  fence(moAcquire)
