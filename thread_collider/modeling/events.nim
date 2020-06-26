# Thread Collider
# Copyright (c) 2020 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

type
  EventKind* = enum
    eAtomic
    eFence
    eLock
    eCondVar
    eThread
    eFutex

  TransitionKind* = enum
    tRead
    tWrite
    tFence
    tLock
    tFutex
    tReleaseSequenceFixup

  Relation = enum
    ## Formal model of C/C++11 memory model Batty et al, 2011
    SequencedBefore
    ReadsFrom
    SynchronizeWith
    HappensBefore
    SequentialConsistency
    ModificationOrder

  AtomicEventKind* = enum
    AtomicRead
    AtomicWrite

  ReadEvent = object
    reorderedLoad*: ReorderedLoad
      ## Handle reordered relaxed atomics

  Event = object
    loc: tuple[filename: string, line: int, column: int]
