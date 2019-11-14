# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[context_global, context_thread_local, sync_types],
  ./channels/[channels_spsc_single, channels_mpsc_bounded_lock],
  ./memory/[persistacks, intrusive_stacks],
  ./config

# Contexts
# ----------------------------------------------------------------------------------

var globalCtx*: GlobalContext
var localCtx* {.threadvar.}: TLContext
  # TODO: tlsEmulation off by default on OSX and on by default on iOS?

const LeaderID*: WorkerID = 0

# Task caching
# ----------------------------------------------------------------------------------

proc newTaskFromCache*(): Task {.inline.} =
  if localCtx.taskCache.isEmpty():
    allocate(result)
  else:
    result = localCtx.taskCache.pop()

# Aliases
# ----------------------------------------------------------------------------------

template myTodoBoxes*: Persistack[PI_MaxConcurrentStealPerWorker, ChannelSpscSingle[Task]] =
  globalCtx.com.tasks[localCtx.worker.ID]

template myThieves*: ChannelMpscBounded[StealRequest] =
  globalCtx.com.thefts[localCtx.worker.ID]

template workforce*: int32 =
  globalCtx.numWorkers

template myID*: WorkerID =
  localCtx.worker.ID

template myWorker*: Worker =
  localCtx.worker

template myTask*: Task =
  localCtx.worker.currentTask

template myThefts*: Thefts =
  localCtx.thefts

template myMetrics*: untyped =
  metrics:
    localCtx.counters

template isRootTask*(task: Task): bool =
  task.parent.isNil

# Dynamic Scopes
# ----------------------------------------------------------------------------------

template Leader*(body: untyped) =
  if localCtx.worker.ID == LeaderID:
    body

template Worker*(body: untyped) =
  if localCtx.worker.ID != LeaderID:
    body
