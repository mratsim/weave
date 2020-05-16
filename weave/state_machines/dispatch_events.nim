# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../instrumentation/[contracts, profilers, loggers],
  ../datatypes/[sync_types, prell_deques, context_thread_local, binary_worker_trees],
  ../contexts, ../config,
  ../victims,
  ../thieves,
  ./decline_thief, ./handle_thieves,
  ../cross_thread_com/channels_mpsc_unbounded_batch

{.push gcsafe.}

proc nextTask*(childTask: static bool): Task {.inline.} =
  # Note:
  # We distinguish jobs and tasks.
  # - Jobs are submitted to Weave by external threads.
  #   Jobs enqueued have all their pledges resolved and so are independent.
  #   To ensure fairness in worst-case scenario, we execute them in FIFO order.
  #   Jobs may be split into multiple tasks.
  # - Tasks are spawned on Weave runtime, we want to process them as fast as possible.
  #   We want to maximize throughput (process them as fast as possible).
  #   To maximize throughput, we execute them in LIFO order.
  #   This ensures that the children of tasks are processed before we try to process their parent.
  #
  # In particular if we have jobs A, B, C that spawns 3 tasks each
  # processing order will be (on a single thread)
  # A2, A1, A0, B2, B1, B0, C2, C1, C0
  # to ensure that job A, B, C have minimized latency and maximized throughput.
  profile(enq_deq_task):
    # Try picking a new task (LIFO)
    if childTask:
      result = myWorker().deque.popFirstIfChild(myTask())
    else:
      result = myWorker().deque.popFirst()

  Manager: # TODO: profiling
    # If we drained the task, try picking a new job (FIFO)
    debugExecutor:
      log("Manager %d: checking jobs (%d in queue)\n", myID(), managerJobQueue.peek())
    if result.isNil:
      var job: Job
      if managerJobQueue.tryRecv(job):
        result = cast[Task](job)

        debugExecutor:
          log("Manager %d: Received job 0x%.08x from provider 0x%.08x\n", myID(), job, job.parent)

  when WV_StealEarly > 0:
    if not result.isNil:
      # If we have a big loop should we allow early thefts?
      stealEarly()

  shareWork()

  # Check if someone requested to steal from us
  # Send them extra tasks if we have them
  # or split our popped task if possible
  handleThieves(result)

proc declineAll*() =
  var req: StealRequest

  profile_stop(idle)

  if recv(req):
    if req.thiefID == myID() and req.state == Working:
      req.state = Stealing
    decline(req)

  profile_start(idle)

proc dispatchToChildrenAndThieves*() =
  shareWork()
  var req: StealRequest
  while recv(req):
    dispatchElseDecline(req)
