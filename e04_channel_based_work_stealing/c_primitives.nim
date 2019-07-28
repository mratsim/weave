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

proc malloc(size: csize): pointer {.header: "<stdio.h>".}

proc malloc*(T: typedesc): ptr T =
  result = malloc(sizeof(T))

proc malloc*(T: typedesc, len: Natural): ptr UncheckedArray[T] =
  result = malloc(sizeof(T) * len)

proc free*(p: pointer) {.header: "<stdio.h>".}
