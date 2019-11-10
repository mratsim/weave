# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[context_global, context_thread_local],
  ./memory/object_pools

# Contexts
# ----------------------------------------------------------------------------------

var globalCtx*: GlobalContext
var localCtx* {.threadvar.}: TLContext
  # TODO: tlsEmulation off by default on OSX and on by default on iOS?

# Dynamic defines
# ----------------------------------------------------------------------------------

when not defined(MaxStealAttempts):
  template MaxStealAttempts*: int32 = globalCtx.numWorkers - 1
    ## Number of steal attempts per steal requests
    ## before a steal request is sent back to the thief
    ## Default value is the number of workers minus one
    ##
    ## The global number of steal requests outstanding
    ## is PicassoMaxStealOutstanding * globalCtx.numWorkers
