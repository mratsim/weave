# Channel implementations

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
Rust design where creating a channel returns distinct receiver and sender
endpoints with only the recv and send proc implemented.
Furthermore we can add a "can only be moved" restrictions for single consumer or single receiver endpoints.
