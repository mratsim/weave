# Channel-based Work Stealing

This is a port of the revised C implementation
from Andreas Prell for the paper:

- Embracing Explicit Communication inWork-Stealing Runtime Systems

  Andreas Prell, PhD Thesis, 2016

  https://epub.uni-bayreuth.de/2990/1/main_final.pdf

- Thesis slides

  http://aprell.github.io/papers/thesis_slides.pdf

- Channel-based Work Stealing, A. Prell, 2014

  http://aprell.github.io/papers/channel_ws_2014.pdf


Thank you Andreas for sharing your code.

## A note on the Nim implementation

The port is following the style of the C original code and has been
only slightly nimified.

This makes it easier when "context-switching" between the 2 codebases.

A typical example is the BoundedStack that uses procedure names
like `bounded_channel_pop` instead of just `pop`.

Another is the used of raw `pthreads`, `printf`, `malloc` and `free`.
This will allow to reproduce the paper results.

## Differences from the original C implementation

The differences are kept minimal. Most are due
to translating C preprocessor's macros
or because Nim offers an equivalent that compiles
to the same hardware instructions,
but using Nim's will make it work on compiler other than GCC and
non-Posix platforms.

- bounded_stack and bounded_queue use generics and static integer parameters
- Only shared memory channels are implemented, no code path for the Intel SCC (Single Chip Cloud experimental CPU).
- Nim locks instead of pthread_mutexes (this is exactly the same on Posix)
- Unit testing uses Nim doAsserts and/or unittest
- Timers have a load fence and memory barrier to prevent compiler instruction reordering.
- In channels, atomic fences are used instead of GCC builtin compiler and memory barriers.
