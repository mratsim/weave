# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Strings
# -------------------------------------------------------

proc printf*(formatstr: cstring) {.header: "<stdio.h>", varargs, sideeffect.}
  # Nim interpolation with "%" doesn't support formatting
  # And strformat requires inlining the variable with the format
  # Furthermore, we want to limit GC usage.

# We use the system malloc to reproduce the original results
# instead of Nim alloc or implementing our own multithreaded allocator
# This also allows us to use normal memory leaks detection tools
# during proof-of-concept stage

# Memory
# -------------------------------------------------------

when defined(windows):
  proc alloca(size: csize): pointer {.header: "<malloc.h>".}
else:
  proc alloca(size: csize): pointer {.header: "<alloca.h>".}

template alloca*(T: typedesc): ptr T =
  cast[ptr T](alloca(sizeof(T)))

template alloca*(T: typedesc, len: Natural): ptr UncheckedArray[T] =
  cast[ptr UncheckedArray[T]](alloca(sizeof(T) * len))

# Random
# -------------------------------------------------------

proc rand_r*(seed: var uint32): int32 {.header: "<stdlib.h>".}
  ## Random number generator from C stdlib
  ## small amount of state
  ## TODO: replace by Nim's
