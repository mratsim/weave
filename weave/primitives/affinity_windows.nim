# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import winlean


when not compileOption("threads"):
    {.error: "This requires --threads:on compilation flag".}

proc setThreadAffinityMask(hThread: Handle, dwThreadAffinityMask: uint) {.
    importc: "SetThreadAffinityMask", stdcall, header: "<windows.h>".}

proc pinToCpu*(cpu: int32) {.inline.} =
  ## Set the affinity of the main thread (the calling thread)
  setThreadAffinityMask(getThreadID(), uint(1 shl cpu))