# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Static configuration & compile-time options
# ----------------------------------------------------------------------------------

const PicassoMaxWorkers* {.intDefine.} = 256
  ## Influences the size of the global context
  # https://github.com/nim-lang/Nim/blob/v1.0.2/lib/pure/concurrency/threadpool.nim#L319-L322

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
