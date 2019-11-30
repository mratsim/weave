# The Channel Graveyard

Welcome the Channel Graveyard.

This directory tracks channels implementations or documentation/research
that has been superceded by more specialized and/or more efficient channels.

Ultimately they should probably go in an external library.

## Bounded SPSC channel research

Thorough research has been done to avoid wasting memory on very small queues and channels.
An innovative scheme by rolling the front and back index at 2xCapacity instead of just 1xCapacity
allows avoiding allocating an extra always empty slot to differentiate between full and empty.
The usual alternative was to allocate a power-of-2 number of slots and use
bit-masking which is even more wasteful in the general case.

Implementation is available in [./channels_mpsc_bounded_lock.nim](channels_mpsc_bounded_lock.nim)
and also used in the main source at [../../weave/datatypes/bounded_queues.nim](bounded_queues.nim)

Turns out we only need SPSC channels of a single slot for tasks and futures/flowvars
so we don't even need head/tail or for pointer we can just test for ``nil``.

## Bounded MPSC channels

Those were used for steal requests when they were stack objects however:
- using pointers (https://github.com/mratsim/weave/pull/13) reduced overhead by 20% combined with lazy futures (5% on normal futures)
- pointers enabled using intrusive list-based lockless channels for steal requests which requires no allocation
  and improves overhead also by about 5% with lazy futures (https://github.com/mratsim/weave/pull/21)

## Bounded MPMC lock-based channels

The bounded MPMC lock-based channel file implements the original channels from the PhD Thesis of Andreas Prell (https://epub.uni-bayreuth.de/2990).
They also provides their own caching mechanism and provides great performance for handling:
- Tasks
- Steal requests
- Futures
The channels uses a 2-lock designs similar to Michael & Scott 2-lock queues (https://www.cs.rochester.edu/u/scott/papers/1996_PODC_queues.pdf).

They were superceded once an efficient, flexible and thread-safe memory management scheme that could also handle releasing memory to the OS has been implemented so that
specialized SPSC channels could also be cached even when passed between threads.

## Unbounded MPSC channels

Those channels were inspired by a mix of:

- Snmalloc MPSC queue
  https://github.com/microsoft/snmalloc/blob/master/snmalloc.pdf (page 4)
  https://github.com/microsoft/snmalloc/blob/7faefbbb0ed69554d0e19bfe901ec5b28e046a82/src/ds/mpscq.h#L29-L83
- Pony-lang queue
  https://qconlondon.com/london-2016/system/files/presentation-slides/sylvanclebsch.pdf
  https://github.com/ponylang/ponyc/blob/7145c2a84b68ae5b307f0756eee67c222aa02fda/src/libponyrt/actor/messageq.c
- Dmitry Vyukov intrusive node-based MPSC queue
  http://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue

Implementation details are here: https://github.com/mratsim/weave/pull/21

The reason for their dismissal is detailed in [channels_mpsc.md](../weave/channels_mpsc.md)
