# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[context_thread_local, sync_types, binary_worker_trees, bounded_queues],
  ./contexts, ./config,
  ./instrumentation/[contracts, loggers, profilers],
  ./memory/persistacks,
  ./channels/channels_spsc_single_ptr

# Signals
# ----------------------------------------------------------------------------------

proc detectTermination*() {.inline.} =
  preCondition: myID() == LeaderID
  preCondition: myWorker().leftIsWaiting and myWorker().rightIsWaiting
  preCondition: not localCtx.runtimeIsQuiescent

  debugTermination:
    log(">>> Worker %2d detects termination <<<\n", myID())

  localCtx.runtimeIsQuiescent = true

proc asyncSignal(fn: proc (_: pointer) {.nimcall, gcsafe.}, chan: var ChannelSpscSinglePtr[Task]) =
  ## Send an asynchronous signal `fn` to channel `chan`

  # Package the signal in a dummy task
  profile(send_recv_task):
    let dummy = newTaskFromCache()
    dummy.fn = fn
    dummy.batch = 1
    # TODO: StealLastVictim

    while not chan.trySend(dummy):
      cpuRelax()
    debugTermination: log("Worker %2d: sending asyncSignal\n", myID())
    # postCondition: signalSent

proc signalTerminate*(_: pointer) {.gcsafe.} =
  preCondition: localCtx.signaled != SignaledTerminate

  # 1. Terminating means everyone ran out of tasks
  #    so their cache for task channels should be full
  #    if there were sufficiently more tasks than workers
  # 2. Since they have an unique parent, no one else sent them a signal (checked in asyncSignal)
  if myWorker().left != Not_a_worker:
    # Send the terminate signal
    asyncSignal(signalTerminate, globalCtx.com.tasks[myWorker().left].access(0))
    Backoff: # Wake the worker up so that it can process the terminate signal
      wakeup(myWorker().left)
  if myWorker().right != Not_a_worker:
    asyncSignal(signalTerminate, globalCtx.com.tasks[myWorker().right].access(0))
    Backoff:
      wakeup(myWorker().right)

  Worker:
    # When processing this signal for our queue, it was counted
    # as a normal task
    decCounter(tasksExec)

  localCtx.signaled = SignaledTerminate

proc signalContinue*(_: pointer) {.gcsafe.} =
  preCondition: localCtx.signaled != SignaledTerminate

  # Reset our steal request cache and empty our worksharing queues
  localCtx.stealCache.reload()
  myWorker().workSharingRequests.initialize()
  myThefts().reload()

  if myWorker().left != Not_a_worker:
    myWorker().leftIsWaiting = false
    asyncSignal(signalContinue, globalCtx.com.tasks[myWorker().left].access(0))
    Backoff: # Wake the worker up so that it can process the continue signal
      wakeup(myWorker().left)
  if myWorker().right != Not_a_worker:
    myWorker().rightIsWaiting = false
    asyncSignal(signalContinue, globalCtx.com.tasks[myWorker().right].access(0))
    Backoff:
      wakeup(myWorker().right)

  Worker:
    # When processing this signal for our queue, it was counted
    # as a normal task
    decCounter(tasksExec)

  localCtx.signaled = SignaledContinue
