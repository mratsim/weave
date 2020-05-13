# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# A job is processing request submitted from outside a Weave worker thread
# They are scheduled in FIFO order and minimize latency for submitters.
# In particular, it is optimized for jobs assumed independent.

# Job Provider
# ----------------------------------------------------------------------------------

import
  # Standard library
  macros, typetraits,
  # Internal
  ./memory/memory_pools,
  ./random/rng,
  ./scheduler, ./contexts,
  ./datatypes/[flowvars, sync_types],
  ./instrumentation/contracts,
  ./cross_thread_com/[scoped_barriers, pledges]

proc setupJobProvider*(_: typedesc[Weave]) {.gcsafe.} =
  ## Configure a thread so that it can submit jobs to the Weave runtime.
  ## This is useful if we want Weave to work
  ## as an independent "service" or "execution engine"
  ## and still being able to offload computation
  ## to it instead of mixing
  ## logic or IO and Weave on the main thread.
  jobProviderContext.mempool.initialize()
  jobProviderContext.rng.seed(getThreadId()) # Seed from the Windows/Unix threadID (not the Weave ThreadID)


proc teardownJobProvider*(_: typedesc[Weave]) {.gcsafe.} =
  ## Maintenance before exiting a JobProvider thread

  # TODO: Have the main thread takeover the mempool if it couldn't be fully released
  let fullyReleased {.used.} = jobProviderContext.mempool.teardown()
