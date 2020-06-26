# Thread Collider
# Copyright (c) 2020 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/tables,
  ../collider_common

# Vector Clocks
# ----------------------------------------------------------------------------------

# Vector Clocks is an algorithm for generating
# a partial ordering of events in a distributed system
# and detecting causality violations.
#
# They are an evolution of Lamport's Timestamps described
# - Time, Clocks and the Ordering of Events in a Distributed System
#   Leslie Lamport, 1978
#   https://amturing.acm.org/p558-lamport.pdf
#
# - Timestamps in Message-Passing Systems That Preserve the Partial Ordering
#   Colin J Fidge, 1988
#   https://zoo.cs.yale.edu/classes/cs426/2012/lab/bib/fidge88timestamps.pdf
#
# - Virtual Time and Global States of Distributed Systems
#   Friedemann Mattern, 1988
#   https://www.vs.inf.ethz.ch/publ/papers/VirtTimeGlobStates.pdf
#
# - Distributed Testing of Concurrent Systems: Vector Clocks to the Rescue
#   Hernàn Ponce-de-Léon, Stefan Haar, and Delphine Longuet, 2014
#   http://www.lsv.fr/Publis/PAPERS/PDF/PHL-ictac14.pdf
#
# - Encoded Vector Clock: Using Primes to Characterize Causalityin Distributed Systems
#   Ajay D. Kshemkalyani, Ashfaq Khokhar, Min Shen
#   https://www.cs.uic.edu/~ajayk/ext/icdcn18_paper19.pdf
#
# - Resettable Encoded Vector Clock for Causality Analysis
#   with an Application to Dynamic Race Detection
#   Tommasso Pozzetti, 2017
#   https://webthesis.biblio.polito.it/12434/1/tesi.pdf
#
# Via a vector of 1 timestamp you can answer the following questions on event ordering / causality:
# - happensBefore?
# - concurrent?
# - impossible?
#
# Logical instructions
# - increment the threadlocal timestamp to represent one thread moving ahead
# - and/or merging two vector clocks to represent 2 threads synchronizing.
#
# However classic VectorClocks are quite bulky.
# They would require seq[TimeStamp] at least (if threads are initialized at once before
# any "interesting" concurrency event)
# or Table[ThreadID, Timestamp] if we want a generic race detection tool that can
# work with threads spawned at any time.
# But Table hashing and the required pointer dereference is an overhead that might prove quite high
# given how many states have to be checked in a concurrent system,
# in particular multi-producer multi-consumer data structures
#
# Furthermore using `seq` or `Table` means involving the GC which is a potential source of
# bugs when working with fibers.
#
# Unfortunately:
# - Encoded Vector Clock have an issue with timestamp growth which is exponential, and may require dynamic allocation
# - Resettable Encoded Vector Clock have an "horizon" of past event beyond which they cannot detect races
#
# So we recreate our own seq ad impose a (configurable) compile-time size to avoid dynamic allocation

type
  Timestamp* = distinct int64

  CausalOrdering* = enum
    ## The ordering relation of 2 distributed events
    ## according to their Vector Clock.
    ##
    ## 2 events are concurrent when their observed timestamps are in "conflict"
    ## And we can't deduce a total ordering.
    Identical
    HappenedBefore
    HappenedAfter
    Concurrent

  VectorClock* = object
    ## A vector clock tracks the partial ordering of event in a distributed system.
    ## 2 clocks can be compared to check if
    ## - 1 event must have happened before the other
    ## - They could happen concurrently
    ## - They violate the laws of causality
    ##
    ## The length is the number of processes/threads tracked
    ## The array of known local timestamps is indexed by the threadID (< len)
    localTS: array[MaxThreads, Timestamp]
    len: int8

proc inc(time: var Timestamp){.borrow.}
proc `$`*(time: Timestamp): string {.borrow.}
proc `<`*(a, b: Timestamp): bool {.borrow.}
proc `==`*(a, b: Timestamp): bool {.borrow.}

proc init*(clock: var VectorClock) {.inline.} =
  ## Initialize a vector clock
  zeroMem(clock.addr, sizeof(clock))

func tick*(clock: var VectorClock, tid: ThreadID) {.inline.}=
  ## Local tick in thread `tid`
  if int8(tid) > clock.len:
    clock.len = int8(tid) + 1
  clock.localTS[tid.int].inc()

func synchronize*(a: var VectorClock, b: VectorClock) {.inline.}=
  ## Synchronize clock `a` with clock `b`
  if b.len > a.len:
    a.len = b.len
  for i in 0 ..< a.len:
    if a.localTS[i] < b.localTS[i]:
      a.localTS[i] = b.localTS[i]

func causality*(a, b: VectorClock): CausalOrdering =
  ## Returns the causal order between 2 vector clocks

  result = Identical
  for i in 0 ..< MaxThreads:
    let tsA = a.localTS[i]
    let tsB = b.localTS[i]

    if tsA == tsB:
      continue
    elif tsA < tsB:
      if result == HappenedAfter:
        return Concurrent
      result = HappenedBefore
    else:
      if result == HappenedBefore:
        return Concurrent
      result = HappenedAfter
  # return Identical

# --------------------------------------------------------------------------------
# Sanity checks

when isMainModule:
  import random

  proc clock[N: static int](a: array[N, int]): VectorClock =
    static: doAssert N <= MaxThreads
    result.len = N.int8
    for i in 0 ..< N:
      result.localTS[i] = TimeStamp(a[i])

  proc randomClock(rng: var Rand, N: static int): VectorClock =
    static: doAssert N <= MaxThreads
    result.len = N.int8
    for i in 0 ..< N:
      result.localTS[i] = TimeStamp(rng.rand(high(int)))

  proc causality[N: static int](a, b: array[N, int]): CausalOrdering =
    clock(a).causality(clock(b))

  proc test_causality() =
    # From https://en.wikipedia.org/wiki/Vector_clock#/media/File:Vector_Clock.svg

    doAssert causality([0, 0, 0], [0, 0, 1]) == HappenedBefore
    doAssert causality([0, 0, 1], [0, 1, 1]) == HappenedBefore
    doAssert causality([0, 1, 1], [0, 2, 1]) == HappenedBefore
    doAssert causality([0, 2, 1], [1, 2, 1]) == HappenedBefore
    doAssert causality([1, 2, 1], [2, 2, 1]) == HappenedBefore

    doAssert causality([0, 2, 1], [0, 3, 1]) == HappenedBefore
    doAssert causality([0, 3, 1], [0, 3, 2]) == HappenedBefore
    doAssert causality([2, 2, 1], [2, 4, 1]) == HappenedBefore
    doAssert causality([0, 3, 1], [2, 4, 1]) == HappenedBefore

    doAssert causality([0, 3, 2], [0, 3, 3]) == HappenedBefore
    doAssert causality([2, 4, 1], [2, 5, 1]) == HappenedBefore
    doAssert causality([0, 3, 3], [3, 3, 3]) == HappenedBefore
    doAssert causality([2, 5, 1], [2, 5, 4]) == HappenedBefore
    doAssert causality([0, 3, 3], [2, 5, 4]) == HappenedBefore

    doAssert causality([2, 5, 4], [2, 5, 5]) == HappenedBefore
    doAssert causality([3, 3, 3], [4, 5, 5]) == HappenedBefore
    doAssert causality([2, 5, 5], [4, 5, 5]) == HappenedBefore

    echo "Causality tests - Happened before - SUCCESS"

    # --------------------------------------------------------

    doAssert causality([0, 3, 1], [1, 2, 1]) == Concurrent
    doAssert causality([0, 3, 1], [2, 2, 1]) == Concurrent
    doAssert causality([1, 2, 1], [0, 3, 1]) == Concurrent
    doAssert causality([2, 2, 1], [0, 3, 1]) == Concurrent

    doAssert causality([2, 4, 1], [0, 3, 2]) == Concurrent
    doAssert causality([2, 5, 1], [0, 3, 2]) == Concurrent
    doAssert causality([2, 4, 1], [0, 3, 3]) == Concurrent
    doAssert causality([2, 5, 1], [0, 3, 3]) == Concurrent

    doAssert causality([3, 3, 3], [2, 5, 4]) == Concurrent
    doAssert causality([3, 3, 3], [2, 5, 5]) == Concurrent

    doAssert causality([3, 3, 3], [2, 4, 1]) == Concurrent
    doAssert causality([3, 3, 3], [2, 5, 1]) == Concurrent

    doAssert causality([0, 3, 2], [1, 2, 1]) == Concurrent
    doAssert causality([0, 3, 2], [2, 2, 1]) == Concurrent
    doAssert causality([2, 2, 1], [0, 3, 3]) == Concurrent

    echo "Causality tests - Concurrency - SUCCESS"

  proc test_invariants(numTests: int) =
    var rng = initRand(seed = numTests)
    for _ in 0 ..< numTests:
      let
        A = rng.randomClock(3)
        B = rng.randomClock(3)
        C = rng.randomClock(3)

      let rel_A_B = causality(A, B)
      let rel_B_C = causality(B, C)
      let rel_A_C = causality(A, C)

      if rel_A_B == Identical:
        # Transitivity
        doAssert rel_B_C == rel_A_C
      elif rel_A_B == HappenedBefore:
        if rel_B_C == HappenedBefore:
          # Transitivity
          doAssert rel_A_C == HappenedBefore
      elif rel_A_B == HappenedAfter:
        if rel_B_C == HappenedAfter:
          # Transitivity
          doAssert rel_A_C == HappenedAfter

      let rel_B_A = causality(B, A)

      case rel_A_B
      of Identical:
        doAssert rel_B_A == Identical
      of HappenedBefore:
        doAssert rel_B_A == HappenedAfter
      of HappenedAfter:
        doAssert rel_B_A == HappenedBefore
      of Concurrent:
        doAssert rel_B_A == Concurrent

    echo "Invariants tests - Transitivity & Commutativity - SUCCESS"

  test_causality()
  test_invariants(10000)
