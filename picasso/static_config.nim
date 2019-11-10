# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import strutils

# Static configuration & compile-time options
# ----------------------------------------------------------------------------------

# const PicassoMaxWorkers* {.intDefine.} = 256
#   ## Influences the size of the global context
#   # https://github.com/nim-lang/Nim/blob/v1.0.2/lib/pure/concurrency/threadpool.nim#L319-L322

# PicassoAsserts: turn on specific assertions independently from
# --assertions:off or -d:danger

const PicassoCacheLineSize* {.intDefine.} = 128
  ## Datastructure that are accessed from multiple threads
  ## are padded by this value to avoid
  ## false sharing / cache threashing / cache ping-pong
  ## Most CPU Arch (x86 and ARM) are 64 bytes.
  ## However, it has been shown that due to some Intel CPU prefetching
  ## 2 cache lines at once, 128 bytes was often necessary.
  ## Samsung Exynos CPU, Itanium, modern PowerPC and some MIPS uses 128 bytes.
  # Nim threadpool uses 32 bytes :/
  # https://github.com/nim-lang/Nim/blob/v1.0.2/lib/pure/concurrency/threadpool.nim

const PicassoMaxSteal* {.intdefine.} = 1
  ## Maximum number of steal requests outstanding per worker
  ## If that maximum is reached a worker will not issue new steal requests
  ## until it receives work.
  ## If the last steal request allowed also fails, the worker will back off
  ## from active stealing and wait for its parent to send work.

static: assert PicassoMaxSteal >= 1

const PicassoStealAdaptativeInterval* {.intdefine.} = 25
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
  PicassoSteal{.strdefine.} = "adaptative"
  PicassoSplit{.strdefine.} = "adaptative"

  StealStrategy* = parseEnum[StealKind](PicassoSteal)
  SplitStrategy* = parseEnum[SplitKind](PicassoSplit)

template metrics*(body: untyped) =
  when defined(PicassoMetrics):
    body

template debugTermination*(body: untyped) =
  when defined(PicassoDebugTermination) or defined(PicassoDebug):
    body

template debug*(body: untyped) =
  when defined(PicassoDebug):
    body

template StealAdaptative*(body: untyped) =
  when StealStrategy == StealKind.adaptative:
    body
