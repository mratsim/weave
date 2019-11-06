# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Task
# ----------------------------------------------------------------------------------

const
  TaskDataSize* = 192 - 96

type
  Task* = ptr TaskObj
    ## Task
    ## Represents a deferred computation that can be passed around threads.
    ## The fields "prev" and "next" can be used
    ## for intrusive containers
  TaskObj = object
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
    sst*: int        # splittable task granularity
    is_loop*: bool
    has_future*: bool
    # List of futures required by the current task
    futures: pointer
    # User data - including the FlowVar channel to send back result.
    data*: array[TaskDataSize, byte]
    # Ideally we can replace fn + data by a Nim closure.

static: assert sizeof(TaskObj) == 192,
          "TaskObj is of size " & $sizeof(TaskObj) &
          " instead of the expected 192 bytes."

proc newTask*(): Task {.inline.} =
  createShared(TaskObj)

proc delete(task: Task) {.inline.} =
  freeShared(task)
