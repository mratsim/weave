# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./datatypes/[context_thread_local, sync_types],
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
    log(">>> Worker %d detects termination <<<\n", myID())

  localCtx.runtimeIsQuiescent = true

proc asyncSignal(fn: proc (_: pointer) {.nimcall.}, chan: var ChannelSpscSinglePtr[Task]) =
  ## Send an asynchronous signal `fn` to channel `chan`

  # Package the signal in a dummy task
  profile(send_recv_task):
    let dummy = newTaskFromCache()
    dummy.fn = fn
    dummy.batch = 1
    # TODO: StealLastVictim

    let signalSent = chan.trySend(dummy)
    debug: log("Worker %d: sending asyncSignal\n", myID())
    postCondition: signalSent

proc signalTerminate*(_: pointer) =
  preCondition: not localCtx.signaledTerminate

  # 1. Terminating means everyone ran out of tasks
  #    so their cache for task channels should be full
  # 2. Since they have an unique parent, no one else sent them a signal (checked in asyncSignal)
  if myWorker().left != -1:
    ascertain: globalCtx.com.tasks[myWorker().left].len == PI_MaxConcurrentStealPerWorker
    asyncSignal(signalTerminate, globalCtx.com.tasks[myWorker().left].access(0))
  if myWorker().right != -1:
    ascertain: globalCtx.com.tasks[myWorker().right].len == PI_MaxConcurrentStealPerWorker
    asyncSignal(signalTerminate, globalCtx.com.tasks[myWorker().right].access(0))

  Worker:
    # When processing this signal for our queue, it was counted
    # as a normal task
    decCounter(tasksExec)

  localCtx.signaledTerminate = true
