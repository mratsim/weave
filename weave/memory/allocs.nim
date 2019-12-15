# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  system/ansi_c

# Helpers
# ----------------------------------------------------------------------------------

proc isPowerOfTwo*(n: int): bool {.inline.} =
  (n and (n - 1)) == 0

# TODO: cannot dispatch at compile-time due to https://github.com/nim-lang/Nim/issues/12726
# but all our use-case are for power of 2

func roundNextMultipleOf*(x: Natural, n: Natural): int {.inline.} =
  assert n.isPowerOfTwo()
  result = (x + n - 1) and not(n - 1)

# func roundNextMultipleOf*(x: Natural, n: static Natural): int {.inline.} =
#   ## Round the input to the next multiple of "n"
#   when n.isPowerOfTwo():
#     # n is a power of 2. (If compiler cannot prove that x>0 it does not make the optim)
#     result = (x + n - 1) and not(n - 1)
#   else:
#     result = ((x + n - 1) div n) * n

# Memory
# ----------------------------------------------------------------------------------

# Nim allocShared, createShared, deallocShared
# take a global lock that is absolutely killing performance
# and shows up either:
# - native_queued_spin_lock_slowpath
# - __pthread_mutex_lock and __pthread_mutex_unlock_usercnt
#
# We use system malloc by default, the flag -d:useMalloc is not enough

template deref*(T: typedesc): typedesc =
  ## Return the base object type behind a ptr type
  typeof(default(T)[])

proc wv_alloc*(T: typedesc): ptr T {.inline.}=
  ## Default allocator for the Picasso library
  ## This allocates memory to hold the type T
  ## and returns a pointer to it
  ##
  ## Can use Nim allocator to measure the overhead of its lock
  ## Memory is not zeroed
  when defined(WV_useNimAlloc):
    createSharedU(T)
  else:
    cast[ptr T](c_malloc(csize_t sizeof(T)))

proc wv_allocPtr*(T: typedesc[ptr], zero: static bool = false): T {.inline.}=
  ## Default allocator for the Picasso library
  ## This allocates memory to hold the
  ## underlying type of the pointer type T.
  ## i.e. if T is ptr int, this allocates an int
  ##
  ## Can use Nim allocator to measure the overhead of its lock
  ## Memory is not zeroed
  result = wv_alloc(deref(T))
  when zero:
    zeroMem(result, sizeof(deref(T)))

proc wv_alloc*(T: typedesc, len: SomeInteger): ptr UncheckedArray[T] {.inline.} =
  ## Default allocator for the Picasso library.
  ## This allocates a contiguous chunk of memory
  ## to hold ``len`` elements of type T
  ## and returns a pointer to it.
  ##
  ## Can use Nim allocator to measure the overhead of its lock
  ## Memory is not zeroed
  when defined(WV_useNimAlloc):
    cast[type result](createSharedU(T, len))
  else:
    cast[type result](c_malloc(csize_t len*sizeof(T)))

proc wv_free*[T: ptr](p: T) {.inline.} =
  when defined(WV_useNimAlloc):
    freeShared(p)
  else:
    c_free(p)

when defined(windows):
  proc alloca(size: csize): pointer {.header: "<malloc.h>".}
else:
  proc alloca(size: csize): pointer {.header: "<alloca.h>".}

template alloca*(T: typedesc): ptr T =
  cast[ptr T](alloca(sizeof(T)))

template alloca*(T: typedesc, len: Natural): ptr UncheckedArray[T] =
  cast[ptr UncheckedArray[T]](alloca(sizeof(T) * len))

when defined(windows):
  proc aligned_alloc(alignment, size: csize_t): pointer {.sideeffect,importc:"_aligned_malloc", header:"<malloc.h>".}
  proc wv_freeAligned*[T](p: ptr T){.sideeffect,importc:"_aligned_free", header:"<malloc.h>".}
elif defined(osx):
  proc posix_memalign(mem: var pointer, alignment, size: csize_t){.sideeffect,importc, header:"<stdlib.h>".}
  proc aligned_alloc(alignment, size: csize_t): pointer {.inline.} =
    posix_memalign(result, alignment, size)
  proc wv_freeAligned*[T](p: ptr T){.inline.} =
    c_free(p)
else:
  proc aligned_alloc(alignment, size: csize_t): pointer {.sideeffect,importc, header:"<stdlib.h>".}
  proc wv_freeAligned*[T](p: ptr T){.inline.} =
    c_free(p)

proc wv_allocAligned*(T: typedesc, alignment: static Natural): ptr T {.inline.} =
  ## aligned_alloc requires allocating in multiple of the alignment.
  static:
    assert alignment.isPowerOfTwo()
  let # TODO - cannot use a const due to https://github.com/nim-lang/Nim/issues/12726
    size = sizeof(T)
    requiredMem = size.roundNextMultipleOf(alignment)
  cast[ptr T](aligned_alloc(csize_t alignment, csize_t requiredMem))
