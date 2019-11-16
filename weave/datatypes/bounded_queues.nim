# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import ../instrumentation/contracts

type
  BoundedQueue*[Capacity: static int, T] = object
    ## Queue with bounded capacity.
    ## The buffer is inline, no heap allocation is required.
    ##
    ## The bounded queue has been fine-tuned for:
    ##   - Memory efficiency: buffer the size of the capacity.
    ##     Unlike many implementations that either require
    ##     a power of 2 size
    ##     or an extra empty slot to differentiate between full and empty.
    ##     This is important as stack space is at a premium.
    ##   - Compute efficiency: no modulo operation (by non-power of 2).
    ##     Modulo is one of the slowest builtin operations and about
    ##     10x slower than other builtins like add, mul, and, or, shifts ...
    ##     Reference: https://www.agner.org/optimize/instruction_tables.pdf
    front, back: int
    buffer: array[Capacity, T]

    # To differentiate between full and empty case
    # we don't rollover the front and back indices to 0
    # when they reach capacity,
    # but only when they reach 2*capacity.
    # When they are the same the queue is empty.
    # When the difference in absolute value is capacity, the queue is full.

func len*(q: BoundedQueue): int {.inline.} =
  result = q.back - q.front
  if result < 0:
    # Case when front in [Capacity, 2*Capacity)
    # and tail in [0, Capacity) range
    # for example for a queue of capacity 7 that rolled twice:
    #
    # | 14 |   |   | 10 | 11 | 12 | 13 |
    #      ^       ^
    #       back    front
    #
    # front is at index 10 (real 3)
    # back is at index 15 (real 1)
    # back - front + capacity = 1 - 3 + 7 = 5
    result += q.Capacity

func isEmpty*(q: BoundedQueue): bool {.inline.} =
  q.front == q.back

func isFull*(q: BoundedQueue): bool {.inline.} =
  abs(q.back - q.front) == q.Capacity

func enqueue*[Capacity: static int, T](
       q: var BoundedQueue[Capacity, T],
       elem: sink T) {.inline.} =
  ## Enqueue an element.
  ## The bounded queue takes ownership of it, the original one
  ## cannot be used anymore.
  ##
  ## This will throw an exception if the queue is full
  ## in debug mode only.
  ## Otherwise it will overwrite the oldest data.
  preCondition:
    not q.isFull()

  let writeIdx = if q.back < Capacity: q.back
                 else: q.back - Capacity
  `=sink`(q.buffer[writeIdx], elem)
  q.back += 1
  if q.back == 2*Capacity:
    q.back = 0

func dequeue*[Capacity: static int, T](
       q: var BoundedQueue[Capacity, T]
     ): owned T {.inline.} =
  ## Dequeue an element.
  ## The bounded queue releases ownership of it
  ##
  ## This will throw an exception if the queue is empty
  ## in debug mode only
  ## Otherwise it will read past the buffer and return
  ## default(T) (assuming Nim `=move` defaults the original)
  preCondition:
    not q.isEmpty()

  let readIdx = if q.front < Capacity: q.front
                else: q.front - Capacity
  result = move q.buffer[readIdx]
  q.front += 1
  if q.front == 2*Capacity:
    q.front = 0

func peek*[Capacity: static int, T](
       q: BoundedQueue[Capacity, T]
     ): lent T {.inline.} =
  ## Immutable view at the next element.
  ## That element is not removed from the queue.
  ##
  ## This will throw an exception if the queue is empty
  ## in debug mode only
  ## Otherwise it will read past the buffer and return
  ## default(T) (assuming Nim `=move` defaults the original)
  preCondition:
    not q.isEmpty()

  let readIdx = if q.front < Capacity: q.front
                else: q.front - Capacity
  result = q.buffer[readIdx]

# Sanity checks
# --------------------------------------------------------------

when isMainModule:
  var q: BoundedQueue[10, int]
  var numbers: array[10, int]

  doAssert q.isEmpty()

  proc runTest(iter: int, q: var BoundedQueue) =
    echo "Running iteration ", iter
    for i in 0 ..< 10:
      numbers[i] = i
      q.enqueue i

    doAssert q.isFull()

    for i in countdown(10, 1):
      let n = q.dequeue()
      doAssert n == numbers[10-i]

    doAssert q.isEmpty()

  for i in 0 ..< 10:
    runTest(i, q)
