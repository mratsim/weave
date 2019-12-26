# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Fast unique thread ID
# This gives unique thread ID suitable for memory allocators.
# Those IDs are not suitable for the Weave runtime
# as for that case, the ID should be the range 0 ..< Weave_NUM_THREADS
# to allow the common pattern or indexing an array by a thread ID.

when (defined(gcc) or defined(clang) or defined(llvm_gcc)) and
  (defined(i386) or defined(amd64) or defined(arm) or defined(arm64)):

  func getMemThreadID*(): int {.inline.} =
    ## Returns a unique thread-local identifier.
    ## This is suitable for memory allocator thread-local identifier
    ## and never requires an expensive syscall.
    # Thread-Local-Storage register on x86 is in the FS or GS register
    # see: https://akkadia.org/drepper/tls.pdf
    when defined(i386):
      asm """
        "movl %%gs:0, %0":"=r"(`result`)::"""
    elif defined(osx):
      asm """
        "movq %%gs:0, %0":"=r"(`result`)::"""
    elif defined(amd64):
      asm """
        "movq %%fs:0, %0":"=r"(`result`)::"""
    elif defined(arm):
      {.emit: ["""asm volatile(
        "mrc p15, 0, %0, c13, c0, 3"
        :"=r"(""", result, """)
      );"""].}
    elif defined(arm64):
      {.emit: ["""asm volatile("mrs %0, tpidr_el0":"=r"(""",result,"));"].}
    else:
      {.error: "Unreachable".}
elif defined(windows):
  proc NtcurrentTeb(): int {.importc, cdecl, header:"<windows.h>".}
    ## Get pointer to Thread Environment BLock
    # Note that ntdll.dll exports this as stdcall but it's a cdecl ¯\_(ツ)_/¯

  func getMemThreadID*(): int {.inline.} =
    ## Returns a unique thread-local identifier.
    ## This is suitable for memory allocator thread-local identifier
    ## and never requires an expensive syscall.
    NtcurrentTeb()
else:
  var dummy {.threadvar.}: byte

  func getMemThreadID*(): int {.inline.} =
    {.noSideEffect.}:
      cast[ByteAddress](dummy.addr)
