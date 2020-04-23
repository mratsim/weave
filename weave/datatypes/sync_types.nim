# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./sparsesets, ./binary_worker_trees,
  ../config,
  ../cross_thread_com/channels_spsc_single_ptr,
  ../instrumentation/contracts,
  std/atomics

# Inter-thread synchronization types
# ----------------------------------------------------------------------------------

const
  TaskDataSize* = 144 # Up to 256 for the whole thing

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
    fn*: proc (param: pointer) {.nimcall, gcsafe.}
    parent*: Task
    prev*: Task
    next*: Task
    # 32 bytes
    start*: int
    cur*: int
    stop*: int
    stride*: int
    # 64 bytes
    futures*: pointer    # LinkedList of futures required by the current task
    futureSize*: uint8   # Size of the future result type if relevant
    hasFuture*: bool     # If a task is associated with a future, the future is stored at data[0]
    isLoop*: bool
    isInitialIter*: bool # Awaitable for-loops return true for the initial iter
    when FirstVictim == LastVictim:
      victim*: WorkerID
    # 79 bytes
    # User data - including the FlowVar channel to send back result.
    # It is very likely that User data contains a pointer (the Flowvar channel)
    # We align to avoid torn reads/extra bookkeeping.
    data*{.align:sizeof(int).}: array[TaskDataSize, byte]

  # Steal requests
  # ----------------------------------------------------------------------------------

  StealRequest* = ptr object
    # TODO: Remove workaround generic atomics bug: https://github.com/nim-lang/Nim/issues/12695
    next*{.align:WV_CacheLinePadding.}: Atomic[pointer]                        # For intrusive lists and queues
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
