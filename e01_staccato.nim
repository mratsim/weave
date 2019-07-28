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

import e01_staccato/scheduler

type FibTask = object of Task[FibTask]
  n: int
  sum: ptr int64

# proc execute(t: var FibTask) =
#   if t.n <= 2:
#     t.sum[] = 1
#     return

#   var x: int64
#   t.child[] = FibTask(n: n-1, sum: x.addr)
#   t.spawn(t.child)

#   var y: int64
#   t.child[] = FibTask(n: n-2, sum: y.addr)
#   t.spawn(t.child)

#   t.wait()

#   t.sum[] = x + y


## This crashes the compiler
## with `Error: internal error: getTypeDescAux(tyOr)`
##
# var x: FibTask
