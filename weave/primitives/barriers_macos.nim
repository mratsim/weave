# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# OSX doesn't implement pthread_barrier_t
# It's an optional part of the POSIX standard
#
# This is a manual implementation of a sense reversing barrier

import locks

type
  Natural32 = range[0'i32..high(int32)]

  Errno* = cint

  PthreadAttr* = object
    ## Dummy
  PthreadBarrier* = object
    ## Implementation of a sense reversing barrier
    ## (The Art of Multiprocessor Programming by Maurice Herlihy & Nir Shavit)

    lock: Lock                      # Alternatively spinlock on Atomic
    cond {.guard: lock.}: Cond
    sense {.guard: lock.}: bool     # Choose int32 to avoid zero-expansion cost in registers?
    left {.guard: lock.}: Natural32 # Number of threads missing at the barrier before opening
    count: Natural32                # Total number of threads that need to arrive before opening the barrier

const
  PTHREAD_BARRIER_SERIAL_THREAD = Errno(1)

proc pthread_cond_broadcast(cond: var Cond): Errno {.header:"<pthread.h>".}
  ## Nim only signal one thread in locks
  ## We need to unblock all

proc broadcast(cond: var Cond) {.inline.}=
  discard pthread_cond_broadcast(cond)

func pthread_barrier_init*(
        barrier: var PthreadBarrier,
        attr: ptr PthreadAttr,
        count: range[0'i32..high(int32)]
      ): Errno =
  barrier.lock.initLock()
  {.locks: [barrier.lock].}:
    barrier.cond.initCond()
    barrier.left = count
  barrier.count = count
  # barrier.sense = false

proc pthread_barrier_wait*(barrier: var PthreadBarrier): Errno =
  ## Wait on `barrier`
  ## Returns PTHREAD_BARRIER_SERIAL_THREAD for a single arbitrary thread
  ## Returns 0 for the other
  ## Returns Errno if there is an error
  barrier.lock.acquire()
  {.locks: [barrier.lock].}:
    var local_sense = barrier.sense # Thread local sense
    dec barrier.left

    if barrier.left == 0:
      # Last thread to arrive at the barrier
      # Reverse phase and release it
      barrier.left = barrier.count
      barrier.sense = not barrier.sense
      barrier.cond.broadcast()
      barrier.lock.release()
      return PTHREAD_BARRIER_SERIAL_THREAD

    while barrier.sense == local_sense:
      # We are waiting for threads
      # Wait for the sense to reverse
      # while loop because we might have spurious wakeups
      barrier.cond.wait(barrier.lock)

    # Reversed, we can leave the barrier
    barrier.lock.release()
    return Errno(0)

proc pthread_barrier_destroy*(barrier: var PthreadBarrier): Errno =
  {.locks: [barrier.lock].}:
    barrier.cond.deinitCond()
  barrier.lock.deinitLock()

# TODO: tests
