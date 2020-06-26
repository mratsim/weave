# Thread Collider
# Copyright (c) 2020 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

static: doAssert defined(i386) or defined(amd64), "Thread Collider requires an x86 or x86_64 CPU at the moment."
  # Constrained by Greenlet/Fibers that are only x86.

# Common types
# ----------------------------------------------------------------------------------

type
  ThreadID* = distinct int8

# ThreadID
# ----------------------------------------------------------------------------------

const MaxThreads* {.intdefine.} = 4
static: doAssert MaxThreads <= high(int8)

var thread_count: ThreadID

proc inc(tid: var ThreadID){.borrow.}
proc `$`*(tid: ThreadID): string {.borrow.}

proc genUniqueThreadID*(): ThreadID =
  result = thread_count
  thread_count.inc()

# Compiler reordering barrier
# ----------------------------------------------------------------------------------
# This prevents the compiler for reordering instructions
# which locks and non-relaxed atomics do (and function calls so we could use non-inline functions)

const someGcc = defined(gcc) or defined(llvm_gcc) or defined(clang)
const someVcc = defined(vcc) or defined(clang_cl)

when someVcc:
  proc compilerReorderingBarrier*(){.importc: "_ReadWriteBarrier", header: "<intrin.h>".}
elif someGcc or defined(tcc):
  proc compilerReorderingBarrier*(){.inline.} =
    {.emit: """asm volatile("" ::: "memory");""".}
else:
  {.error: "Unsupported compiler".}
