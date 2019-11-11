# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import strutils

# Static configuration & compile-time options
# ----------------------------------------------------------------------------------

# const PI_MaxWorkers* {.intDefine.} = 256
#   ## Influences the size of the global context
#   # https://github.com/nim-lang/Nim/blob/v1.0.2/lib/pure/concurrency/threadpool.nim#L319-L322

# PI_Asserts: turn on specific assertions independently from
# --assertions:off or -d:danger

# PI_Profile: turn on profiling

const PI_CacheLineSize* {.intDefine.} = 128
  ## Datastructure that are accessed from multiple threads
  ## are padded by this value to avoid
  ## false sharing / cache threashing / cache ping-pong
  ## Most CPU Arch (x86 and ARM) are 64 bytes.
  ## However, it has been shown that due to some Intel CPU prefetching
  ## 2 cache lines at once, 128 bytes was often necessary.
  ## Samsung Exynos CPU, Itanium, modern PowerPC and some MIPS uses 128 bytes.
  # Nim threadpool uses 32 bytes :/
  # https://github.com/nim-lang/Nim/blob/v1.0.2/lib/pure/concurrency/threadpool.nim

const PI_MaxConcurrentStealPerWorker* {.intdefine.}: int8 = 1
  ## Maximum number of steal requests outstanding per worker
  ## If that maximum is reached a worker will not issue new steal requests
  ## until it receives work.
  ## If the last steal request allowed also fails, the worker will back off
  ## from active stealing and wait for its parent to send work.

static:
  assert PI_MaxConcurrentStealPerWorker >= 1, "Workers need to send at least a steal request"
  assert PI_MaxConcurrentStealPerWorker <= high(int8), "It's a work-stealing scheduler not a thieves guild!"

const PI_StealAdaptativeInterval* {.intdefine.} = 25
  ## Number of steal requests after which a worker reevaluate
  ## the steal-half vs steal-one strategy

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
  PI_Steal{.strdefine.} = "adaptative"
  PI_Split{.strdefine.} = "adaptative"

  StealStrategy* = parseEnum[StealKind](PI_Steal)
  SplitStrategy* = parseEnum[SplitKind](PI_Split)

# Static scopes
# ----------------------------------------------------------------------------------

template metrics*(body: untyped): untyped =
  when defined(PI_Metrics):
    body

template debugTermination*(body: untyped): untyped =
  when defined(PicassoDebugTermination) or defined(PicassoDebug):
    body

template debug*(body: untyped): untyped =
  when defined(PicassoDebug):
    body

template StealAdaptative*(body: untyped): untyped =
  when StealStrategy == StealKind.adaptative:
    body

# Dynamic defines
# ----------------------------------------------------------------------------------

when not defined(PI_MaxRetriesPerSteal):
  template PI_MaxRetriesPerSteal*: int32 = workforce() - 1
    ## Number of steal attempts per steal requests
    ## before a steal request is sent back to the thief
    ## Default value is the number of workers minus one
    ##
    ## The global number of steal requests outstanding
    ## is PI_MaxConcurrentStealPerWorker * globalCtx.numWorkers
