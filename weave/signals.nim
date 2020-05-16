# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[context_thread_local, sync_types, binary_worker_trees],
  ./contexts, ./config,
  ./instrumentation/[contracts, loggers, profilers],
  ./memory/persistacks,
  ./cross_thread_com/[channels_spsc_single_ptr, scoped_barriers]

{.push gcsafe.}

# Signals
# ----------------------------------------------------------------------------------

proc detectTermination*() {.inline.} =
  preCondition: myID() == RootID
  preCondition: myWorker().leftIsWaiting and myWorker().rightIsWaiting
  preCondition: not workerContext.runtimeIsQuiescent

  debugTermination:
    log(">>> Worker %2d detects termination <<<\n", myID())

  workerContext.runtimeIsQuiescent = true

proc asyncSignal(fn: proc (_: pointer) {.nimcall, gcsafe.}, chan: var ChannelSpscSinglePtr[Task]) =
  ## Send an asynchronous signal `fn` to channel `chan`

  # Package the signal in a dummy task
  profile(send_recv_task):
    let dummy = newTaskFromCache()
    dummy.fn = fn
    dummy.parent = myTask()
    mySyncScope().registerDescendant
    dummy.scopedBarrier = mySyncScope()
    TargetLastVictim:
      dummy.victim = Not_a_worker

    let signalSent {.used.} = chan.trySend(dummy)
    debugTermination: log("Worker %2d: sending asyncSignal\n", myID())
    postCondition: signalSent

proc signalTerminate*(_: pointer) =
  preCondition: not workerContext.signaledTerminate

  # 1. Terminating means everyone ran out of tasks
  #    so their cache for task channels should be full
  #    if there were sufficiently more tasks than workers
  # 2. Since they have an unique parent, no one else sent them a signal (checked in asyncSignal)
  if myWorker().left != Not_a_worker:
    # Send the terminate signal
    asyncSignal(signalTerminate, globalCtx.com.tasksStolen[myWorker().left].access(0))
    Backoff: # Wake the worker up so that it can process the terminate signal
      wakeup(myWorker().left)
  if myWorker().right != Not_a_worker:
    asyncSignal(signalTerminate, globalCtx.com.tasksStolen[myWorker().right].access(0))
    Backoff:
      wakeup(myWorker().right)

  Worker:
    # When processing this signal for our queue, it was counted
    # as a normal task
    decCounter(tasksExec)

  workerContext.signaledTerminate = true
