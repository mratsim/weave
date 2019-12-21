# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# An implementation of futex using Windows primitives

import std/atomics, winlean
export MemoryOrder

type
  Futex* = Atomic[int32]

# Contrary to the documentation, the futex related primitives are NOT in kernel32.dll
# but in api-ms-win-core-synch-l1-2-0.dll ¯\_(ツ)_/¯

proc WaitOnAddress(
        Address: pointer, CompareAddress: pointer,
        AddressSize: csize_t, dwMilliseconds: DWORD
       ): WINBOOL {.importc, stdcall, dynlib: "api-ms-win-core-synch-l1-2-0".}
  # The Address should be volatile

proc WakeByAddressSingle(Address: pointer) {.importc, stdcall, dynlib: "api-ms-win-core-synch-l1-2-0".}

proc wait*(futex: var Futex, refVal: int32) {.inline.} =
  ## Suspend a thread if the value of the futex is the same as refVal.

  # Returns TRUE if the wait succeeds or FALSE if not.
  # getLastError() will contain the error information, for example
  # if it failed due to a timeout.
  # We discard as this is not needed and simplifies compat with Linux futex
  discard WaitOnAddress(futex.addr, refVal.unsafeAddr, csize_t sizeof(refVal), INFINITE)

proc wake*(futex: var Futex) {.inline.} =
  ## Wake one thread (from the same process)
  WakeByAddressSingle(futex.addr)

proc initialize*(futex: var Futex) {.inline.} =
  futex.store(0, moRelaxed)