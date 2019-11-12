# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./instrumentation/[contracts, profilers],
  ./primitives/barriers,
  ./datatypes/[sync_types, prell_deques, context_thread_local],
  ./channels/[channels_mpsc_bounded_lock, channels_spsc_single],
  ./memory/persistacks,
  ./contexts, ./config


# Public routine
# ----------------------------------------------------------------------------------

proc sync*() =
  ## Sync all threads
  discard globalCtx.barrier.pthread_barrier_wait()

# Local context
# ----------------------------------------------------------------------------------

proc init(ctx: var TLContext) =
  ## Initialize the thread-local context of a worker (including the lead worker)

  myWorker().deque = newPrellDeque(Task)
  myThieves().initialize(PI_MaxConcurrentStealPerWorker * workforce())
  myTodoBoxes().initialize()
  myWorker().initialize(maxID = workforce())

  ascertain: myTodoBoxes().len == PI_MaxConcurrentStealPerWorker

  # Workers see their RNG with their ID
  myThefts().rng = uint32 myID()

  # Thread-Local Profiling
  profile_init(run_task)
  profile_init(enq_deq_task)
  profile_init(send_recv_task)
  profile_init(send_recv_req)
  profile_init(idle)

# Scheduler
# ----------------------------------------------------------------------------------

proc worker_entry_fn(id: WorkerID) =
  ## On the start of the threadpool workers will execute this
  ## until they receive a termination signal
  # We assume that thread_local variables start all at their binary zero value
  preCondition: localCtx == default(TLContext)

  myID() = id # If this crashes, you need --tlsemulation:off
