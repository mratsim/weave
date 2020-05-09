# Thread Collider
# Copyright (c) 2020 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./vector_clocks

# Reordered loads
# ----------------------------------------------------------------------------------
#
#
# Motivating example
# ```Nim
#  var x {.noInit.}, y {.noInit.}: Atomic[int32]
#  x.store(0, moRelaxed)
#  y.store(0, moRelaxed)
#
#  proc threadA() =
#    let r1 = y.load(moRelaxed)
#    x.store(1, moRelaxed)
#    echo "r1 = ", r1
#
#  proc threadA() =
#    let r2 = x.load(moRelaxed)
#    y.store(1, moRelaxed)
#    echo "r2 = ", r2
#
#  spawn threadA()
#  spawn threadB()
#  ```
#
#  It is possible to have r1 = 1 and r2 = 1 for this program,
#  contrary to first intuition.
#
#  I.e. we can see that before setting one of x or y to 1
#  a load at least must have happened, and so those load should be 0.
#
#  However, under a relaxed memory model, given that those load-store
#  are on different variables, the compiler can reorder the program to:
#
# ```Nim
#  var x {.noInit.}, y {.noInit.}: Atomic[int32]
#  x.store(0, moRelaxed)
#  y.store(0, moRelaxed)
#
#  proc threadA() =
#    x.store(1, moRelaxed)
#    let r1 = y.load(moRelaxed)
#    echo "r1 = ", r1
#
#  proc threadA() =
#    y.store(1, moRelaxed)
#    let r2 = x.load(moRelaxed)
#    echo "r2 = ", r2
#
#  spawn threadA()
#  spawn threadB()
#  ```
#
#  And so we need to introduce a read from reordered loads

type
  ReorderedValue = object
    value: uint64
    expiry: VectorClock
    srcThread: ThreadID

  ReorderedLoad* = ref object
    rv: ReorderedValue
