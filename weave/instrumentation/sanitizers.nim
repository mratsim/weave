# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Address sanitizer
# ----------------------------------------------------------------------------------

proc asan_poison_memory_region(region: pointer, size: int){.nodecl, importc:"__asan_poison_memory_region".}
proc asan_unpoison_memory_region(region: pointer, size: int){.nodecl, importc:"__asan_unpoison_memory_region".}

const WV_SanitizeAddr*{.booldefine.} = false

when WV_SanitizeAddr:
  when not(defined(gcc) or defined(clang) or defined(llvm_gcc)):
    {.error: "Address Sanitizer requires GCC or Clang".}
  else:
    {.passC:"-fsanitize=address".}
    {.passL:"-fsanitize=address".}
    when defined(clang) and defined(amd64):
      {.passL:"-lclang_rt.asan_dynamic-x86_64".}
    else:
      {.error: "Compiler + CPU arch configuration missing".}

template poisonMemRegion*(region: pointer, size: int) =
  when WV_SanitizeAddr:
    asan_poison_memory_region(region, size)
  else:
    discard

template unpoisonMemRegion*(region: pointer, size: int) =
  when WV_SanitizeAddr:
    asan_unpoison_memory_region(region, size)
  else:
    discard