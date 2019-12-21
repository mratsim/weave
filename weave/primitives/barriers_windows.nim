# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import winlean

type
  SynchronizationBarrier*{.importc:"SYNCHRONIZATION_BARRIER", header:"<synchapi.h>".} = object

var SYNCHRONIZATION_BARRIER_FLAGS_NO_DELETE* {.importc, header: "<synchapi.h>".}: DWORD
  ## Skip expensive checks on barrier enter if a barrier is never deleted.

proc EnterSynchronizationBarrier*(lpBarrier: var SynchronizationBarrier, dwFlags: DWORD): WINBOOL {.importc, stdcall, header: "<synchapi.h>".}
proc DeleteSynchronizationBarrier*(lpBarrier: ptr SynchronizationBarrier) {.importc, stdcall, header: "<synchapi.h>".}
proc InitializeSynchronizationBarrier*(lpBarrier: var SynchronizationBarrier, lTotalThreads: LONG, lSpinCount: LONG): WINBOOL {.importc, stdcall, header: "<synchapi.h>".}

when isMainModule:
  import os

  var x{.noinit.}: SynchronizationBarrier
  let err = InitializeSynchronizationBarrier(x, 2, -1)
  if err != 1:
    assert err == 0
    raiseOSError(osLastError())