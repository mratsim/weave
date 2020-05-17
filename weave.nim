# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  weave/[
    parallel_tasks, parallel_for, parallel_for_staged,
    runtime],
  weave/state_machines/[sync_root, sync, sync_scope],
  weave/datatypes/flowvars,
  weave/cross_thread_com/flow_events,
  weave/contexts,
  weave/[executor, parallel_jobs]

export
  Flowvar, Weave,
  spawn, sync, syncRoot,
  parallelFor, parallelForStrided,
  init, exit,
  loadBalance,
  isSpawned, isReady,
  getThreadId, getNumThreads,
  # Experimental threadlocal prologue/epilogue
  parallelForStaged, parallelForStagedStrided,
  # Experimental scope barrier
  syncScope,
  # Experimental dataflow parallelism
  spawnOnEvents, FlowEvent,
  trigger, newFlowEvent,
  # Experimental background service
  Pending,
  submit, submitOnEvents,
  runInBackground, waitUntilReady,
  setupSubmitterThread, teardownSubmitterThread,
  waitFor, isSubmitted,
  processAllandTryPark,
  runForever, runUntil
