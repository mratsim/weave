# Thread Collider

Thread Collider is a [formal verification](https://en.wikipedia.org/wiki/Formal_verification) tool
to highlight concurrency bugs in Nim multithreaded programs and data structures.

It uses [Model Checking](https://en.wikipedia.org/wiki/Model_checking) techniques to exhaustively investigate
all possible interleavings (if it has enough time) of your threads and variable states
and ensure that your assumptions, represented by asserts or liveness properties (no deadlocks/livelocks),
holds in a concurrent environment.

Thread Collider has been designed with the C11/C++11 memory model in my mind. It is aware of relaxed memory semantics
and can detect races that involve atomic variables and fences that involves relaxed, acquire and release synchronization semantics.

## References

- RFC: Correct-by-Construction Nim programs\
  https://github.com/nim-lang/RFCs/issues/222

- \[Testing\] Concurrency: Race detection / Model Checking / Formal Verification\
  https://github.com/mratsim/weave/issues/18
