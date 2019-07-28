# 01 - port of staccato: https://github.com/rkuchumov/staccato
#
# Characteristics:
# - help-first / child-stealing
# - leapfrogging
# - Tasks stored as object instead of pointer or closure
#   - to limit memory fragmentation and cache misses
#   - avoid having to deallocate the pointer/closure
#
# Notes:
# - There is one scheduler per instantiated type.
#   This might oversubscribe the system if we schedule
#   something on float and another part on int

# when not compileOption("threads"):
#     {.error: "This requires --threads:on compilation flag".}

# import


# type ComputePiTask = object of Task[ComputePiTask]
#   iterStart: int
#   iterEnd: int

# var a: ComputePiTask
# a.iterEnd = 100

# echo a
