# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/context_thread_local,
  ./contexts,
  ./instrumentation/contracts,
  ./config

# Signals
# ----------------------------------------------------------------------------------

proc detectTermination*() {.inline.} =
  preCondition: myID() == LeaderID
  preCondition: localCtx.worker.leftIsWaiting and localCtx.worker.rightIsWaiting
  preCondition: not localCtx.runtimeIsQuiescent

  debugTermination:
    log(">>> Worker %d detects termination <<<\n", myID())

  localCtx.runtimeIsQuiescent = true
