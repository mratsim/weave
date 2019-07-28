# Strings
# -------------------------------------------------------

proc printf*(formatstr: cstring) {.header: "<stdio.h>", varargs, sideeffect.}
  # Nim interpolation with "%" doesn't support formatting
  # And strformat requires inlining the variable with the format

# We use the system malloc to reproduce the original results
# instead of Nim alloc or implementing our own multithreaded allocator
# This also allows us to use normal memory leaks detection tools
# during proof-of-concept stage

# Memory
# -------------------------------------------------------

func malloc(size: csize): pointer {.header: "<stdio.h>".}
  # We consider that malloc as no side-effect
  # i.e. it never fails
  #      and we don't care about pointer addresses

func malloc*(T: typedesc): ptr T =
  result = cast[type result](malloc(sizeof(T)))

func malloc*(T: typedesc, len: Natural): ptr UncheckedArray[T] =
  result = cast[type result](malloc(sizeof(T) * len))

func free*(p: pointer) {.header: "<stdio.h>".}
  # We consider that free as no side-effect
  # i.e. it never fails
