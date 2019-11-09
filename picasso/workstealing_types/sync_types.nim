# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./helpers, ./victims_bitsets,
  ../static_config,
  ../channels/channels_spsc_single

# Inter-thread synchronization types
# ----------------------------------------------------------------------------------

const
  TaskDataSize* = 192 - 96

type
  # Worker
  # ----------------------------------------------------------------------------------
  WorkerID* = int32
  WorkerState* = enum
    ## Steal requests carry one of the following states:
    ## - Working means the requesting worker is (likely) still busy
    ##   but anticipating running out of tasks
    ## - Stealing means the requesting worker has run out of tasks
    ##   and is trying to steal some
    ## - Waiting means the requesting worker backs off and waits for tasks
    ##   from its parent worker
    Working
    Stealing
    Waiting

  # Task
  # ----------------------------------------------------------------------------------

  Task* = ptr object
    ## Task
    ## Represents a deferred computation that can be passed around threads.
    ## The fields "prev" and "next" can be used
    ## for intrusive containers
    # We save memory by using int32 instead of int on select properties
    parent*: Task
    prev*: Task
    next*: Task
    fn*: proc (param: pointer) {.nimcall.}
    batch*: int32
    victim*: int32
    start*: int
    cur*: int
    stop*: int
    chunks*: int
    splitThreshold*: int # TODO: can probably be removed with the adaptative algorithm
    isLoop*: bool
    hasFuture*: bool
    # List of futures required by the current task
    futures: pointer
    # User data - including the FlowVar channel to send back result.
    data*: array[TaskDataSize, byte]
    # Ideally we can replace fn + data by a Nim closure.

    # TODO: support loops with steps


  # Steal requests
  # ----------------------------------------------------------------------------------

  # Padding shouldn't be needed as steal requests are used as value types
  # and deep-copied between threads
  StealRequest* = object
    taskChannel*: ptr ChannelSpscSingle[Task] # Channel for sending tasks back to the requester
    thiefID*: WorkerID
    retry*: int32                             # 0 <= retry <= num_workers
    victims*: VictimsBitset                   # bitfield of potential victims
    state*: WorkerState                       # State of the thief
    when StealStrategy == StealKind.adaptative:
      stealHalf: bool                         # Thief wants half the tasks

static: assert sizeof(deref(Task)) == 192,
          "Task is of size " & $sizeof(deref(Task)) &
          " instead of the expected 192 bytes."

# StealableTask API
proc allocate*(task: var Task) {.inline.} =
  task = createShared(deref(Task))

proc delete*(task: Task) {.inline.} =
  freeShared(task)
