# OSX doesn't implement pthread_barrier_t
# as it's an optional part of the POSIX standard
#
# So we need to roll our own barrier.
# We need to make sure that we don't hit the same bug
# as glibc: https://sourceware.org/bugzilla/show_bug.cgi?id=13065
# which seems to be an issue in some of the barrier implementations
# in the wild.

# The design of Glibc barriers is here:
# https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/DESIGN-barrier.txt;h=23463c6b7e77231697db3e13933b36ce295365b1;hb=HEAD
#
# And implementation:
# - https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_barrier_destroy.c;h=76957adef3ee751e5b0cfa429fcf4dd3cfd80b2b;hb=HEAD
# - https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_barrier_init.c;h=c8ebab3a3cb5cbbe469c0d05fb8d9ca0c365b2bb;hb=HEAD`
# - https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_barrier_wait.c;h=49fcfd370c1c4929fdabdf420f2f19720362e4a0;hb=HEAD

# This article goes over the techniques of
# "pool barrier" and "ticket barrier"
# https://locklessinc.com/articles/barriers/
# to reach 2x to 20x the speed of pthreads barrier
#
# This course https://cs.anu.edu.au/courses/comp8320/lectures/aux/comp422-Lecture21-Barriers.pdf
# goes over
# - centralized barrier with sense reversal
# - combining tree barrier
# - dissemination barrier
# - tournament barrier
# - scalable tree barrier
# More courses:
# - http://www.cs.rochester.edu/u/sandhya/csc458/seminars/jb_Barrier_Methods.pdf

# It however requires lightweight mutexes like Linux futexes
# that OSX lacks.
#
# This post goes over lightweight mutexes like Benaphores (from BeOS)
# https://preshing.com/20120226/roll-your-own-lightweight-mutex/

# This gives a few barrier implementations
# http://gallium.inria.fr/~maranget/MPRI/02.pdf
# and refers to Cubible paper for formally verifying synchronization barriers
# http://cubicle.lri.fr/papers/jfla2014.pdf (in French)

import locks

type
  Natural32 = range[0'i32..high(int32)]

  Errno* = distinct cint

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
