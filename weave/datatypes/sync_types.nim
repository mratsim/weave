# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./sparsesets, ./binary_worker_trees,
  ../config,
  ../channels/channels_spsc_single_ptr,
  ../instrumentation/contracts,
  ../memory/allocs,
  std/atomics

# Inter-thread synchronization types
# ----------------------------------------------------------------------------------

const
  TaskDataSize* = 192 - 96

type
  # Task
  # ----------------------------------------------------------------------------------

  Task* = ptr object
    ## Task
    ## Represents a deferred computation that can be passed around threads.
    ## The fields "prev" and "next" can be used
    ## for intrusive containers
    # We save memory by using int32 instead of int on select properties
    # order field by size to optimize zero initialization (bottleneck on recursive algorithm)
    fn*: proc (param: pointer) {.nimcall.}
    parent*: Task
    prev*: Task
    next*: Task
    # 32 bytes
    start*: int
    cur*: int
    stop*: int
    stride*: int
    # 64 bytes
    futures*: pointer # List of futures required by the current task
    batch*: int32 # TODO remove
    isLoop*: bool
    hasFuture*: bool
    # 78 bytes
    # User data - including the FlowVar channel to send back result.
    data*: array[TaskDataSize, byte]

    # TODO: support loops with steps


  # Steal requests
  # ----------------------------------------------------------------------------------

  # Padding shouldn't be needed as steal requests are used as value types
  # and deep-copied between threads
  StealRequest* = ptr object
    # TODO: padding to cache line
    # TODO: Remove workaround generic atomics bug: https://github.com/nim-lang/Nim/issues/12695
    next*: Atomic[pointer]                        # For intrusive lists and queues
    thiefAddr*: ptr ChannelSpscSinglePtr[Task]    # Channel for sending tasks back to the thief
    thiefID*: WorkerID
    retry*: int32                                 # 0 <= retry <= num_workers
    victims*: SparseSet                           # set of potential victims
    state*: WorkerState                           # State of the thief
    when StealStrategy == StealKind.adaptative:
      stealHalf*: bool                            # Thief wants half the tasks

# Ensure unicity of a given steal request
# -----------------------------------------------------------
# Unfortunately Nim compiler cannot infer in while loops that
# all paths will sink the current value

# proc `=`(dest: var StealRequest, source: StealRequest) {.error: "A Steal Request must be unique and cannot be copied".}
