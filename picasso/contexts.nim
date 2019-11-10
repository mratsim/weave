# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[context_global, context_thread_local, sync_types],
  ./channels/[channels_spsc_single, channels_mpsc_bounded_lock],
  ./memory/persistacks,
  ./static_config

# Contexts
# ----------------------------------------------------------------------------------

var globalCtx*: GlobalContext
var localCtx* {.threadvar.}: TLContext
  # TODO: tlsEmulation off by default on OSX and on by default on iOS?

# Aliases
# ----------------------------------------------------------------------------------

template myTodoBoxes*: Persistack[PicassoMaxStealsOutstanding, ChannelSpscSingle[Task]] =
  globalCtx.com.tasks[localCtx.worker.ID]

template myThieves*: ChannelMpscBounded[StealRequest] =
  globalCtx.com.thefts[localCtx.worker.ID]

template workforce*: int32 =
  globalCtx.numWorkers

template myID*: WorkerID =
  localCtx.worker.ID

template myThefts*: Thefts =
  localCtx.thefts

template myMetrics*: Counters =
  localCtx.counters

# Dynamic defines
# ----------------------------------------------------------------------------------

when not defined(PicassoMaxStealAttempts):
  template PicassoMaxStealAttempts*: int32 = workforce() - 1
    ## Number of steal attempts per steal requests
    ## before a steal request is sent back to the thief
    ## Default value is the number of workers minus one
    ##
    ## The global number of steal requests outstanding
    ## is PicassoMaxStealsOutstanding * globalCtx.numWorkers
