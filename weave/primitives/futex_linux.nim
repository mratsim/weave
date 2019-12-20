# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# A wrapper for linux futex.
# Condition variables do not always wake on signal which can deadlock the runtime
# so we need to roll up our sleeves and use the low-level futex API.

import std/atomics, ../instrumentation/loggers
export MemoryOrder

const
  NR_Futex = 202
  FutexPrivateFlag = 128

type
  Futex* = distinct Atomic[int32]

  FutexOp {.size: sizeof(cint).}= enum
    FutexWait = 0
    FutexWake = 1
    # ...
    FutexWaitPrivate = 0 or FutexPrivateFlag # If all threads belong to the same process
    FutexWakePrivate = 1 or FutexPrivateFlag # If all threads belong to the same process

when not defined(release) or not defined(danger):
  var SysFutexDbg {.importc:"SYS_futex", header: "<sys/syscall.h>".}: cint
  assert NR_Futex == SysFutexDbg, "Your platform is misconfigured"

  var FutexWaitDbg {.importc:"FUTEX_WAIT", header: "<linux/futex.h>".}: cint
  assert ord(FutexWait) == FutexWaitDbg, "Your platform is misconfigured"

  var FutexWakeDbg {.importc:"FUTEX_WAKE", header: "<linux/futex.h>".}: cint
  assert ord(FutexWake) == FutexWakeDbg, "Your platform is misconfigured"

  var FutexWaitPrivateDbg {.importc:"FUTEX_WAIT_PRIVATE", header: "<linux/futex.h>".}: cint
  assert ord(FutexWaitPrivate) == FutexWaitPrivateDbg, "Your platform is misconfigured"

  var FutexWakePrivateDbg {.importc:"FUTEX_WAKE_PRIVATE", header: "<linux/futex.h>".}: cint
  assert ord(FutexWakePrivate) == FutexWakePrivateDbg, "Your platform is misconfigured"

proc syscall(sysno: clong): cint {.header:"<sys/syscall.h>", varargs.}

proc sysFutex(
       futex: var Futex, op: FutexOp, val1: cint,
       timeout: pointer = nil, val2: pointer = nil, val3: cint = 0): cint {.inline.} =
  syscall(NR_Futex, futex.addr, op, val1, timeout, val2, val3)

proc wait*(futex: var Futex, refVal: int32): cint {.inline.} =
  ## Suspend a thread if the value of the futex is the same as refVal.
  ## Returns 0 in case of a successful suspend
  ## If value are different, it returns EWOULDBLOCK
  sysFutex(futex, FutexWaitPrivate, refVal)

proc wake*(futex: var Futex): cint {.inline.} =
  ## Wake one thread (from the same process)
  ## Returns the number of actually woken thread
  ## or a Posix error code (if negative)
  sysFutex(futex, FutexWakePrivate, 1)

proc load*(futex: var Futex, memOrder: MemoryOrder): int32 {.inline.} =
  Atomic[int32](futex).load(memOrder)

proc store*(futex: var Futex, val: int32, memOrder: MemoryOrder) {.inline.} =
  Atomic[int32](futex).store(val, memOrder)

proc initialize*(futex: var Futex) {.inline.} =
  futex.store(0, moRelaxed)
