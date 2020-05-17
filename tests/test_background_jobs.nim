# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[atomics, os],
  ../weave

proc main() =
  var shutdownWeave, serviceDone: Atomic[bool]
  shutdownWeave.store(false, moRelaxed)
  serviceDone.store(false, moRelaxed)

  var executorThread: Thread[ptr Atomic[bool]]
  executorThread.runInBackground(Weave, shutdownWeave.addr)

  block: # Have an independant display service submit jobs to Weave
    serviceDone.store(false, moRelaxed)

    proc display_int(x: int): bool =
      stdout.write(x)
      stdout.write(" - SUCCESS\n")

      return true

    proc displayService(serviceDone: ptr Atomic[bool]) =
      setupSubmitterThread(Weave)
      waitUntilReady(Weave)

      echo "Sanity check 1: Printing 123456 654321 in parallel"
      discard submit display_int(123456)
      let ok = submit display_int(654321)

      discard waitFor(ok)
      serviceDone[].store(true, moRelaxed)

    var t: Thread[ptr Atomic[bool]]
    t.createThread(displayService, serviceDone.addr)
    joinThread(t)

  block: # Job that spawns tasks
    serviceDone.store(false, moRelaxed)

    proc async_fib(n: int): int =

      if n < 2:
        return n

      let x = spawn async_fib(n-1)
      let y = async_fib(n-2)

      result = sync(x) + y

    proc fibonacciService(serviceDone: ptr Atomic[bool]) =
      setupSubmitterThread(Weave)
      waitUntilReady(Weave)

      echo "Sanity check 2: fib(20)"
      let f = submit async_fib(20)

      echo waitFor(f)
      serviceDone[].store(true, moRelaxed)

    var t: Thread[ptr Atomic[bool]]
    t.createThread(fibonacciService, serviceDone.addr)
    joinThread(t)

  block: # Delayed computation
    serviceDone.store(false, moRelaxed)

    proc echoA(pA: FlowEvent) =
      echo "Display A, sleep 1s, create parallel streams 1 and 2"
      sleep(1000)
      pA.trigger()

    proc echoB1(pB1: FlowEvent) =
      echo "Display B1, sleep 1s"
      sleep(1000)
      pB1.trigger()

    proc echoB2() =
      echo "Display B2, exit stream"

    proc echoC1(): bool =
      echo "Display C1, exit stream"

    proc echoService(serviceDone: ptr Atomic[bool]) =
      setupSubmitterThread(Weave)
      waitUntilReady(Weave)

      echo "Sanity check 3: Dataflow parallelism"
      let pA = newFlowEvent()
      let pB1 = newFlowEvent()
      let done = submitOnEvent(pB1, echoC1())
      submitOnEvent pA, echoB2()
      submitOnEvent pA, echoB1(pB1)
      submit echoA(pA)

      discard waitFor(done)
      serviceDone[].store(true, moRelaxed)

    var t: Thread[ptr Atomic[bool]]
    t.createThread(echoService, serviceDone.addr)
    joinThread(t)

  block: # Delayed computation with multiple dependencies
    serviceDone.store(false, moRelaxed)

    proc echoA(pA: FlowEvent) =
      echo "Display A, sleep 1s, create parallel streams 1 and 2"
      sleep(1000)
      pA.trigger()

    proc echoB1(pB1: FlowEvent) =
      echo "Display B1, sleep 1s"
      sleep(1000)
      pB1.trigger()

    proc echoB2(pB2: FlowEvent) =
      echo "Display B2, no sleep"
      pB2.trigger()

    proc echoC12(): bool =
      echo "Display C12, exit stream"
      return true

    proc echoService(serviceDone: ptr Atomic[bool]) =
      setupSubmitterThread(Weave)
      waitUntilReady(Weave)

      echo "Sanity check 4: Dataflow parallelism with multiple dependencies"
      let pA = newFlowEvent()
      let pB1 = newFlowEvent()
      let pB2 = newFlowEvent()
      let done = submitOnEvents(pB1, pB2, echoC12())
      submitOnEvent pA, echoB2(pB2)
      submitOnEvent pA, echoB1(pB1)
      submit echoA(pA)

      discard waitFor(done)
      serviceDone[].store(true, moRelaxed)

    var t: Thread[ptr Atomic[bool]]
    t.createThread(echoService, serviceDone.addr)
    joinThread(t)

  # Wait until all tests are done
  var backoff = 1
  while not serviceDone.load(moRelaxed):
    sleep(backoff)
    backoff *= 2
    if backoff > 16:
      backoff = 16

  shutdownWeave.store(true)

main()
