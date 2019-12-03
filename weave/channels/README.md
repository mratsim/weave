# Communications channels

In this folder, you will find all cross-thread synchronization types used in Weave.

The main type is the Channel which comes in different flavors depending on its use.

To prevent polling an empty channel uselessly
Channels can be associated with an event notifier, that will park them and only wake them up when required.

## Channels

There are many ways to implement channels with different use-cases and different tradeoffs.

Implementations will follow the following scheme

`channel_`+ sync + `_` + kind + `_` + buf/unbuf + `_` + optional_name

sync is underlying synchronization method:
  - shm for shared memory
Names to be defined for distributed computing or hardware message-passing

kind:
  - spsc: Single Producer Single Consumer
  - mpsc: Multi Producer Single Consumer
  - mpmc: Multi Producer Multi Consumer

unbuf/bounded/unbounded:
  - unbuf: unbuffered channel (also called rendezvous). Blocking.
  - single: channel can only buffer a single element
  - bounded: channel has a max pre-allocated capacity. Usually array-based.
  - unbounded: channel has no max capacity. List-based.

optional_name:
  if the channel implementation is following a paper
  use this optional name to quickly identify it.
  For example michael_scott for an MPMC channel based
  on Michael & Scott queue

API:

For now we follow Nim channels example with the channel being shared
between senders and receivers however it might be interesting to explore
[Rust's Crossbeam](https://docs.rs/crossbeam-channel/0.3.9/crossbeam_channel/) or [Adobe's Stlab](http://stlab.cc/libraries/concurrency/channel/channel.html) design where creating a channel returns distinct receiver and sender
endpoints with only the recv and send proc implemented.
Furthermore we can add a "can only be moved" restrictions for single consumer or single receiver endpoints.

It prevents misuse of channels however for Weave:
- We store all channels in a context/global, with the sender/receiver distinction
  it will be twice the size (and potentially twice the cache misses).
- It would require tracing for the channel buffer to be destroyed
  when no more receivers and/or senders exists, increasing book keeping overhead.
- Reference counting would have to be done manually and in a thread-safe manner as there is no way to use Nim's GC and a custom object pool.
- In our case the context/global owns the channels so tracing is not required
- For this reason, using a raw pointer instead of owned ref
  in the Sender[T] and Receiver[T] wrapper is possible.
  ```Nim
  type
    Channel[Capacity: static int, T] = object
      ...
    Sender[Capacity: static int, T] = object
      chan: ptr Channel[Capacity, T]
    Receiver[Capacity: static int, T] = object
      chan: ptr Channel[Capacity, T]
  ```
- However the safety gains seem low compared to cognitive overhead as
  channel lifetime, non-copiable SPSC, performance are already addressed
  by a channel pool. Receiver/Sender would be 2 more types to manage/alias.
- And having a pointer indirection increases cache misses.
