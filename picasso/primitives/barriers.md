# Synchronization Barriers

OSX does not implement pthread_barrier as its an optional part
of the POSIX standard and they probably want to drive people to libdispatch/Grand Central Dispatch.

So we need to roll our own with a POSIX compatible API.

## Glibc barriers, design bug and implementation

> Note: due to GPL licensing, do not lift the code.
>       Not that we can as it is heavily dependent on futexes
>       which are not available on OSX

We need to make sure that we don't hit the same bug
as glibc: https://sourceware.org/bugzilla/show_bug.cgi?id=13065
which seems to be an issue in some of the barrier implementations
in the wild.

The design of Glibc barriers is here:
https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/DESIGN-barrier.txt;h=23463c6b7e77231697db3e13933b36ce295365b1;hb=HEAD

And implementation:
- https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_barrier_destroy.c;h=76957adef3ee751e5b0cfa429fcf4dd3cfd80b2b;hb=HEAD
- https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_barrier_init.c;h=c8ebab3a3cb5cbbe469c0d05fb8d9ca0c365b2bb;hb=HEAD`
- https://sourceware.org/git/?p=glibc.git;a=blob;f=nptl/pthread_barrier_wait.c;h=49fcfd370c1c4929fdabdf420f2f19720362e4a0;hb=HEAD

## Synchronization barrier techniques

This article goes over the techniques of
"pool barrier" and "ticket barrier"
https://locklessinc.com/articles/barriers/
to reach 2x to 20x the speed of pthreads barrier

This course https://cs.anu.edu.au/courses/comp8320/lectures/aux/comp422-Lecture21-Barriers.pdf
goes over
- centralized barrier with sense reversal
- combining tree barrier
- dissemination barrier
- tournament barrier
- scalable tree barrier
More courses:
- http://www.cs.rochester.edu/u/sandhya/csc458/seminars/jb_Barrier_Methods.pdf

It however requires lightweight mutexes like Linux futexes
that OSX lacks.

This post goes over lightweight mutexes like Benaphores (from BeOS)
https://preshing.com/20120226/roll-your-own-lightweight-mutex/

This gives a few barrier implementations
http://gallium.inria.fr/~maranget/MPRI/02.pdf
and refers to Cubible paper for formally verifying synchronization barriers
http://cubicle.lri.fr/papers/jfla2014.pdf (in French)
