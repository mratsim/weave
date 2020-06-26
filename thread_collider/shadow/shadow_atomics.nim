# Thread Collider
# Copyright (c) 2020 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Common types
# ----------------------------------------------------------------------------------

type
  MemoryOrder* = enum
      ## Specifies how non-atomic operations can be reordered around atomic
      ## operations.

      moRelaxed
        ## No ordering constraints. Only the atomicity and ordering against
        ## other atomic operations is guaranteed.

      # moConsume
      #   ## This ordering is currently discouraged as it's semantics are
      #   ## being revised. Acquire operations should be preferred.

      moAcquire
        ## When applied to a load operation, no reads or writes in the
        ## current thread can be reordered before this operation.

      moRelease
        ## When applied to a store operation, no reads or writes in the
        ## current thread can be reorderd after this operation.

      moAcquireRelease
        ## When applied to a read-modify-write operation, this behaves like
        ## both an acquire and a release operation.

      moSequentiallyConsistent
        ## Behaves like Acquire when applied to load, like Release when
        ## applied to a store and like AcquireRelease when applied to a
        ## read-modify-write operation.
        ## Also guarantees that all threads observe the same total ordering
        ## with other moSequentiallyConsistent operations.
