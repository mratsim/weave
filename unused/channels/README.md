# Unused channels implementations

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

## Bounded MPSC channels

Those were used for steal requests when they were stack objects however:
- using pointers (https://github.com/mratsim/weave/pull/13) reduced overhead by 20% combined with lazy futures (5% on normal futures)
- pointers enabled using intrusive list-based lockless channels for steal requests which requires no allocation
  and improves overhead also by about 5% with lazy futures (https://github.com/mratsim/weave/pull/21)
