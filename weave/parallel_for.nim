# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Parallel for loops
# ----------------------------------------------------------
# Parallel reductions/folds are dispatch to the parallel_reduce file

import
  # Standard library
  macros,
  # Internal
  ./parallel_macros, ./parallel_reduce,
  ./contexts, ./runtime, ./config,
  ./instrumentation/contracts,
  ./datatypes/flowvars, ./await_fsm,
  ./channels/pledges,
  ./parallel_tasks

when not compileOption("threads"):
  {.error: "This requires --threads:on compilation flag".}

template parallelForWrapper(
    idx: untyped{ident},
    prologue, loopBody, epilogue,
    remoteAccum, resultTy,
    returnStmt: untyped): untyped =
  ## To be called within a loop task
  ## Gets the loop bounds and iterate the over them
  ## Also poll steal requests in-between iterations
  ##
  ## Loop prologue, epilogue,
  ## remoteAccum, resultTy and returnStmt
  ## are unused
  loadBalance(Weave)

  block:
    let this = myTask()
    ascertain: this.isLoop
    ascertain: this.start == this.cur

    var idx {.inject.} = this.start
    this.cur += this.stride
    while idx < this.stop:
      loopBody
      idx += this.stride
      this.cur += this.stride
      loadBalance(Weave)

template parallelForAwaitableWrapper(
    idx: untyped{ident},
    prologue, loopBody, epilogue,
    remoteAccum, resultTy,
    returnStmt: untyped): untyped =
  ## To be called within a loop task
  ## Gets the loop bounds and iterate the over them
  ## Also poll steal requests in-between iterations.
  ##
  ## For awaitable loops, the thread that spawned the loop
  ## will be blocked at the end until all the other parallel
  ## loop iterations are finished. The other threads
  ## only waits for their loop iterations and the loop splits they produced.
  ##
  ## For example for a range 0 ..< 100 spawned by thread 0
  ## Thread 1 might get 50 ..< 100 then distribute
  ## 75 ..< 100 to thread 2. After finishing 75 ..< 100
  ## thread 2 is not blocked. Thread 1 needs to wait for thread 2.
  ##
  ## Blocking doesn't prevent processing tasks or scheduling.
  ##
  ## Loop prologue, epilogue,
  ## remoteAccum, resultTy and returnStmt
  ## are unused
  loadBalance(Weave)

  let this = myTask()
  block:
    ascertain: this.isLoop
    ascertain: this.start == this.cur

    var idx {.inject.} = this.start
    this.cur += this.stride
    while idx < this.stop:
      loopBody
      idx += this.stride
      this.cur += this.stride
      loadBalance(Weave)

  debugSplit: log("Worker %2d: Finished loop task 0x%.08x (iterations [%ld, %ld)) (futures: 0x%.08x)\n", myID(), this.fn, this.start, this.stop, this.futures)
  block: # Wait for the child loop iterations
    while not this.futures.isNil:
      let fvNode = cast[FlowvarNode](this.futures)
      this.futures = cast[pointer](fvNode.next)

      LazyFV:
        let dummyFV = cast[Flowvar[Dummy]](fvNode.lfv)
      EagerFV:
        let dummyFV = cast[Flowvar[Dummy]](fvNode.chan)

      debugSplit: log("Worker %2d: loop task 0x%.08x (iterations [%ld, %ld)) waiting for the remainder\n", myID(), this.fn, this.start, this.stop)
      sync(dummyFV)
      debugSplit: log("Worker %2d: loop task 0x%.08x (iterations [%ld, %ld)) complete\n", myID(), this.fn, this.start, this.stop)

      # The "sync" in the merge statement should have recycled the flowvar channel already
      # For LazyFlowVar, the LazyFlowvar itself was allocated on the heap, so we need to recycle it as well
      # 2 deallocs for eager FV and 3 for Lazy FV
      recycleFVN(fvNode)

proc parallelForSplitted(index, start, stop, stride, captured, capturedTy, dependsOn, body: NimNode): NimNode =
  ## In case a parallelFor depends on iteration pledge indexed by the loop variable
  ## we can't use regular parallel loop with lazy splitting
  ## we need to split the loop eagerly so that each iterations can be started independently
  ## as soo as the corresponding iteration pledge is fulfilled.
  ## In that case, the loop cannot have futures.

  result = newStmtList()
  let parForSplitted = ident("weaveTask_DelayedParForSplit_")
  var fnCall = newCall(bindSym"spawnDelayed")

  let pledge = dependsOn[0]

  if captured.len > 0:
    let captured = if captured.len > 1: captured
                   else: captured[0]

    result.add quote do:
      proc `parForSplitted`(`index`: SomeInteger, captures: `capturedTy`) {.nimcall, gcsafe.} =
        let `captured` = captures
        `body`

      for `index` in countup(`start`, `stop`-1, `stride`):
        spawnDelayed(`pledge`, `index`, `parForSplitted`(`index`, `captured`))
  else:
    result.add quote do:
      proc `parForSplitted`(`index`: SomeInteger) {.nimcall, gcsafe.} =
        `body`

      for `index` in countup(`start`, `stop`-1, `stride`):
        spawnDelayed(`pledge`, `index`, `parForSplitted`(`index`))

macro parallelForImpl(loopParams: untyped, stride: int, body: untyped): untyped =
  ## Parallel for loop
  ## Syntax:
  ##
  ## parallelFor i in 0 ..< 10:
  ##   echo(i)
  ##
  ## Variables from the external scope needs to be explicitly captured
  ##
  ##  var a = 100
  ##  var b = 10
  ##  parallelFor i in 0 ..< 10:
  ##    captures: {a, b}
  ##    echo a + b + i

  result = newStmtList()

  # Loop parameters
  # --------------------------------------------------------
  let (idx, start, stop) = extractLP(loopParams)

  # Extract resulting flowvar and captured variables
  # --------------------------------------------------------
  let (future, captured, capturedTy) = body.extractFutureAndCaptures()

  let withFuture = not future.isNil
  let withArgs = capturedTy.len > 0

  let CapturedTy = ident"CapturedTy"
  if withArgs:
    result.add quote do:
      type `CapturedTy` = `capturedTy`

  result.addSanityChecks(capturedTy, CapturedTy)

  # Pledges
  # --------------------------------------------------------
  # TODO: support multiple pledges
  let dependsOn = extractPledges(body)
  # If the input dependencies depends on the loop index
  # we need to eagerly split our lazily scheduled loop
  # as iterations cannot be scheduled at the same type
  # It also cannot be awaited with regular sync.

  if dependsOn.kind == nnkPar and dependsOn[1].eqIdent(idx):
    return parallelForSplitted(idx, start, stop, stride, captured, capturedTy, dependsOn, body)

  # Package the body in a proc
  # --------------------------------------------------------
  let parForName = if withFuture: ident"weaveParallelForAwaitableSection"
                   else: ident"weaveParallelForSection"
  let env = ident("weaveParForClosureEnv_") # typed pointer to data
  let wrapper = if withFuture: bindSym"parallelForAwaitableWrapper"
                else: bindSym"parallelForWrapper"
  result.add packageParallelFor(
                parForName, wrapper,
                # prologue, loopBody, epilogue,
                nil, body, nil,
                # remoteAccum, return statement
                nil, nil,
                idx, env,
                captured, capturedTy,
                resultFvTy = nil
              )

  # Create the async function (that calls the proc that packages the loop body)
  # --------------------------------------------------------
  let parForTask = if withFuture: ident("weaveTask_ParallelForAwaitable_")
                   else: ident("weaveTask_ParallelFor_")
  var fnCall = newCall(parForName)
  if withArgs:
    fnCall.add(env)

  var futTy: NimNode

  if not withFuture:
    result.add quote do:
      proc `parForTask`(param: pointer) {.nimcall, gcsafe.} =
        let this = myTask()
        assert not isRootTask(this)

        when bool(`withArgs`):
          let `env` = cast[ptr `CapturedTy`](param)
        `fnCall`
  else:
    let dummyFut = ident"dummyFut"
    futTy = nnkBracketExpr.newTree(
      bindSym"Flowvar", bindSym"Dummy"
    )
    result.add quote do:
      proc `parForTask`(param: pointer) {.nimcall, gcsafe.} =
        let this = myTask()
        assert not isRootTask(this)

        let `dummyFut` = cast[ptr `futTy`](param)
        when bool(`withArgs`):
          # This requires lazy futures to have a fixed max buffer size
          let offset = cast[pointer](cast[ByteAddress](param) +% sizeof(`futTy`))
          let `env` = cast[ptr `CapturedTy`](offset)
        `fnCall`
        readyWith(`dummyFut`[], Dummy())

  # Create the task
  # --------------------------------------------------------
  result.addLoopTask(
    parForTask, start, stop, stride, captured, CapturedTy,
    futureIdent = future, resultFutureType = futTy
  )

  # echo result.toStrLit

macro parallelFor*(loopParams: untyped, body: untyped): untyped =
  ## Parallel for loop.
  ## Syntax:
  ##
  ## parallelFor i in 0 ..< 10:
  ##   echo(i)
  ##
  ## Variables from the external scope needs to be explicitly captured
  ##
  ##  var a = 100
  ##  var b = 10
  ##  parallelFor i in 0 ..< 10:
  ##    captures: {a, b}
  ##    echo a + b + i
  ##
  ## A parallel for loop can be awaited
  ##
  ##  var a = 100
  ##  var b = 10
  ##  parallelFor i in 0 ..< 10:
  ##    captures: {a, b}
  ##    awaitable: myLoopHandle
  ##    echo a + b + i
  ##
  ##  sync(myLoopHandle)
  ##
  ## In templates and generic procedures, you need to use "mixin myLoopHandle"
  ## or declare the awaitable handle before the loop to workaround Nim early symbol resolution

  # TODO - support pledge in reduction
  if (body[0].kind == nnkCall and body[0][0].eqIdent"reduce") or
     (body.len >= 2 and
     body[1].kind == nnkCall and body[1][0].eqIdent"reduce"):
    result = getAST(parallelReduceImpl(loopParams, 1, body))
  else:
    result = getAST(parallelForImpl(loopParams, 1, body))

macro parallelForStrided*(loopParams: untyped, stride: Positive, body: untyped): untyped =
  if (body[0].kind == nnkCall and body[0][0].eqIdent"reduce") or
     (body.len >= 2 and
     body[1].kind == nnkCall and body[1][0].eqIdent"reduce"):
    result = getAST(parallelReduceImpl(loopParams, stride, body))
  else:
    result = getAST(parallelForImpl(loopParams, stride, body))

# Sanity checks
# --------------------------------------------------------

when isMainModule:
  import ./instrumentation/loggers, ./runtime, ./runtime_fsm, os

  block:
    proc main() =
      init(Weave)

      parallelFor i in 0 ..< 100:
        log("%d (thread %d)\n", i, myID())

      exit(Weave)

    echo "Simple parallel for"
    echo "-------------------------"
    main()
    echo "-------------------------"

  block: # Capturing outside scope
    proc main2() =
      init(Weave)

      var a = 100
      var b = 10
      # expandMacros:
      parallelFor i in 0 ..< 10:
        captures: {a, b}
        log("a+b+i = %d (thread %d)\n", a+b+i, myID())

      exit(Weave)


    echo "\n\nCapturing outside variables"
    echo "-------------------------"
    main2()
    echo "-------------------------"


  block: # Nested loops
    proc main3() =
      init(Weave)

      parallelFor i in 0 ..< 4:
        parallelFor j in 0 ..< 8:
          captures: {i}
          log("Matrix[%d, %d] (thread %d)\n", i, j, myID())

      exit(Weave)

    echo "\n\nNested loops"
    echo "-------------------------"
    main3()
    echo "-------------------------"

  block: # Strided Nested loops
    proc main4() =
      init(Weave)

      # expandMacros:
      parallelForStrided i in 0 ..< 200, stride = 30:
        parallelForStrided j in 0 ..< 400, stride = 60:
          captures: {i}
          log("Matrix[%d, %d] (thread %d)\n", i, j, myID())

      exit(Weave)

    echo "\n\nStrided Nested loops"
    echo "-------------------------"
    main4()
    echo "-------------------------"

  block: # Awaitable for loops
    proc main5() =
      var M = createSharedU(array[1000..1099, array[200, int]])

      init(Weave)

      parallelFor i in 1000 ..< 1100:
        captures: {M}
        parallelFor j in 0 ..< 200:
          captures: {i, M}
          awaitable: innerJ
          M[i][j] = 1000 * i + 1000 * j

        sync(innerJ)
        # Check that the sync worked
        for j in 0 ..< 200:
          let Mij = M[i][j]
          let expected = 1000 * i + 1000 * j
          ascertain: Mij == expected

      exit(Weave)


    echo "\n\nNested awaitable for-loop"
    echo "-------------------------"
    main5()
    echo "-------------------------"

  block:
    proc main6() =
      init(Weave)

      let pA = newPledge(0, 10, 1)
      let pB = newPledge(0, 10, 1)

      parallelFor i in 0 ..< 10:
        captures: {pA}
        sleep(i * 10)
        pA.fulfill(i)
        echo "Step A - stream ", i, " at ", i * 10, " ms"

      parallelFor i in 0 ..< 10:
        dependsOn: (pA, i)
        captures: {pB}
        sleep(i * 10)
        pB.fulfill(i)
        echo "Step B - stream ", i, " at ", 2 * i * 10, " ms"

      parallelFor i in 0 ..< 10:
        dependsOn: (pB, i)
        sleep(i * 10)
        echo "Step C - stream ", i, " at ", 3 * i * 10, " ms"

      exit(Weave)

    echo "Dataflow loop parallelism"
    echo "-------------------------"
    main6()
    echo "-------------------------"
