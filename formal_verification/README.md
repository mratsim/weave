# Formal Verification

To ensure that Weave synchronization data structures are free of
concurrency bugs, deadlocks or livelocks they are formally verified via model checking.

The event notifier which parks idle threads and wake them up when receiving tasks
has been formally implemented verified via TLA+ (Temporal Logic of Action).

TLA+ is an industrial-strength formal specification language, model checker and can plug into proof assistant to prove properties of code.
It is used at Microsoft and Amazon to validate bug-free distributed protocol or at Intel to ensure that that the memory of a CPU is free of cache-coherency bugs.

Link: https://lamport.azurewebsites.net/tla/tla.html


Weave Multi-Producer Single-Consumer queue has been implemented in C++ and run through CDSChecker, a model checking tool for C++11 atomics.

It exhaustively checks all possible thread interleavings to ensure that no path lead to a bug.

Note: Due to CDSChecker running out of "snapshotting memory" (to rollback to a previous program state) when using dlmalloc `mspace` functions, the checks are not complete.

Link: http://plrg.ics.uci.edu/software_page/42-2/
