# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import strutils

# With C++ we need C++11
# ----------------------------------------------------------------------------------

when defined(cpp):
  {.passC:"-std=c++11".}

# Static configuration & compile-time options
# ----------------------------------------------------------------------------------

const WV_MaxWorkers* {.intDefine.} = 255
  ## Influences the size of the size of the sets of victims
  # https://github.com/nim-lang/Nim/blob/v1.0.2/lib/pure/concurrency/threadpool.nim#L319-L322

# WV_Asserts: turn on specific assertions independently from
# --assertions:off or -d:danger

# WV_Profile: turn on profiling

const WV_CacheLinePadding* {.intDefine.} = 128
  ## Datastructure that are accessed from multiple threads
  ## are padded by this value to avoid
  ## false sharing / cache threashing / cache ping-pong
  ## Most CPU Arch (x86 and ARM) are 64 bytes.
  ## However, it has been shown that due to some Intel CPU prefetching
  ## 2 cache lines at once, 128 bytes was often necessary.
  ## Samsung Exynos CPU, Itanium, modern PowerPC and some MIPS uses 128 bytes.
  # Nim threadpool uses 32 bytes :/
  # https://github.com/nim-lang/Nim/blob/v1.0.2/lib/pure/concurrency/threadpool.nim

const WV_MaxConcurrentStealPerWorker* {.intdefine.}: int8 = 1
  ## Maximum number of steal requests outstanding per worker
  ## If that maximum is reached a worker will not issue new steal requests
  ## until it receives work.
  ## If the last steal request allowed also fails, the worker will back off
  ## from active stealing and wait for its parent to send work.

static:
  assert WV_MaxConcurrentStealPerWorker >= 1, "Workers need to send at least a steal request"
  assert WV_MaxConcurrentStealPerWorker <= high(int8), "It's a work-stealing scheduler not a thieves guild!"

const WV_StealAdaptativeInterval* {.intdefine.} = 25
  ## Number of steal requests after which a worker reevaluate
  ## the steal-half vs steal-one strategy

const WV_StealEarly* {.intdefine.} = 0
  ## Workers with less tasks than WV_StealEarly will initiate
  ## steal requests in advance. This might help hide stealing latencies
  ## or worsen message overhead.

const WV_EnableBackoff* {.booldefine.} = false
  ## Workers that fail to find work will sleep. This saves CPU at the price
  ## of slight latency as the workers' parent nodes need to manage their
  ## steal requests queues when they sleep and there is latency to wake up.

type
  StealKind* {.pure.}= enum
    one
    half
    adaptative

  SplitKind* {.pure.}= enum
    half
    guided
    adaptative

const
  WV_Steal{.strdefine.} = "adaptative"
  WV_Split{.strdefine.} = "adaptative"

  StealStrategy* = parseEnum[StealKind](WV_Steal)
  SplitStrategy* = parseEnum[SplitKind](WV_Split)

# Static scopes
# ----------------------------------------------------------------------------------

template metrics*(body: untyped): untyped =
  when defined(WV_Metrics):
    {.noSideEffect, gcsafe.}: body

template debugTermination*(body: untyped): untyped =
  when defined(WV_DebugTermination) or defined(WV_Debug):
    {.noSideEffect, gcsafe.}: body

template debug*(body: untyped): untyped =
  when defined(WV_Debug):
    {.noSideEffect, gcsafe.}: body

template StealAdaptative*(body: untyped): untyped =
  when StealStrategy == StealKind.adaptative:
    body

template LazyFV*(body: untyped): untyped =
  when defined(WV_LazyFlowvar):
    body

template EagerFV*(body: untyped): untyped =
  when not defined(WV_LazyFlowvar):
    body

template Backoff*(body: untyped): untyped =
  when WV_EnableBackoff:
    body

# Dynamic defines
# ----------------------------------------------------------------------------------

when not defined(WV_MaxRetriesPerSteal):
  template WV_MaxRetriesPerSteal*: int32 = maxID()
    ## Number of steal attempts per steal requests
    ## before a steal request is sent back to the thief
    ## Default value is the number of workers minus one
    ##
    ## The global number of steal requests outstanding
    ## is WV_MaxConcurrentStealPerWorker * globalCtx.numWorkers
