# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Parallel reductions
# ----------------------------------------------------------

import
  # Standard library
  macros,
  # Internal
  ./parallel_macros,
  ./contexts, ./config,
  ./instrumentation/[contracts, profilers],
  ./datatypes/flowvars

when not compileOption("threads"):
  {.error: "This requires --threads:on compilation flag".}

template parallelStagedWrapper(
  idx: untyped{ident},
  prologue, loopBody, epilogue,
  remoteAccum, resultFlowvarType,
  returnStmt: untyped): untyped =
  ## To be called within a loop task
  ## Gets the loop bounds and iterate the over them
  ## Also poll steal requests in-between iterations
  ##
  ## remoteAccum and resultFlowvarType are unused
  loadBalance(Weave)

  prologue

  block: # Loop body
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

  epilogue

template parallelStagedAwaitableWrapper(
  idx: untyped{ident},
  prologue, loopBody, epilogue,
  remoteAccum, resultFlowvarType,
  returnStmt: untyped): untyped =
  ## To be called within a loop task
  ## Gets the loop bounds and iterate the over them
  ## Also poll steal requests in-between iterations
  ##
  ## remoteAccum and resultFlowvarType are unused
  loadBalance(Weave)

  prologue

  let this = myTask()
  block: # Loop body
    ascertain: this.isLoop
    ascertain: this.start == this.cur

    var idx {.inject.} = this.start
    this.cur += this.stride
    while idx < this.stop:
      loopBody

      idx += this.stride
      this.cur += this.stride
      loadBalance(Weave)

  epilogue

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

macro parallelForStagedImpl*(loopParams: untyped, stride: int, body: untyped): untyped =
  ## Parallel for loop with prologue and epilogue stages
  ## Syntax:
  ##
  ##   var sum: int
  ##   let ptrSum = sum.addr
  ##
  ##   parallelForStaged i in 0 ..< 100:
  ##     captures: {ptrSum}
  ##     prologue:
  ##       ## Initialize thread-local values
  ##       var localSum = 0
  ##     loop:
  ##       ## Compute the partial reductions
  ##       localSum += i
  ##     epilogue:
  ##       ## Add our local reduction to the global sum
  ##       ## This requires lock or atomics for synchronization
  ##       ptrSum.atomicInc(localSum)
  result = newStmtList()

  # Loop parameters
  # --------------------------------------------------------
  let (idx, start, stop) = extractLP(loopParams)

  # Extract captured variables
  # --------------------------------------------------------
  let (future, captured, capturedTy) = body.extractFutureAndCaptures()

  let withFuture = not future.isNil
  let withArgs = capturedTy.len > 0

  let CapturedTy = ident"CapturedTy" # workaround for GC-safe check
  if withArgs:
    result.add quote do:
      type `CapturedTy` = `capturedTy`

  result.addSanityChecks(capturedTy, CapturedTy)

  # Extract the reduction configuration
  # --------------------------------------------------------
  let (prologue, loopBody, epilogue) = extractStagedConfig(body, withArgs, withFuture)

  # Package the body in a proc
  # --------------------------------------------------------
  let parStagedName = if withFuture: ident"weaveParallelStagedAwaitableSection"
                      else: ident"weaveParallelStagedSection"
  let env = ident("weaveParallelStagedSectionClosureEnv_") # typed pointer to data
  let wrapper = if withFuture: bindSym"parallelStagedAwaitableWrapper"
                else: bindSym"parallelStagedWrapper"
  result.add packageParallelFor(
                parStagedName, wrapper,
                # prologue, loopBody, epilogue,
                prologue, loopBody, epilogue,
                # remoteAccum, return statement
                nil, nil,
                idx, env,
                captured, capturedTy,
                resultFvTy = nil
              )

  # Create the async function (that calls the proc that packages the loop body)
  # --------------------------------------------------------
  let parStagedTask = if withFuture: ident("weaveTask_ParallelStagedAwaitable_")
                      else: ident("weaveTask_ParallelStaged_")
  var fnCall = newCall(parStagedName)
  if withArgs:
    fnCall.add(env)

  var futTy: NimNode

  if not withFuture:
    result.add quote do:
      proc `parStagedTask`(param: pointer) {.nimcall, gcsafe.} =
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
      proc `parStagedTask`(param: pointer) {.nimcall, gcsafe.} =
        let this = myTask()
        assert not isRootTask(this)

        let `dummyFut` = cast[ptr `futTy`](param)
        when bool(`withArgs`):
          # This requires lazy futures to have a fixed max buffer size
          let offset = cast[pointer](cast[ByteAddress](param) +% sizeof(`futTy`))
          let `env` = cast[ptr `CapturedTy`](offset)
        `fnCall`
        `dummyFut`[].readyWith(Dummy())

  # Create the task
  # --------------------------------------------------------
  result.addLoopTask(
    parStagedTask, start, stop, stride, captured, CapturedTy,
    futureIdent = future, resultFutureType = futTy
  )

  # echo result.toStrLit

macro parallelForStaged*(loopParams: untyped, body: untyped): untyped =
  result = getAST(parallelForStagedImpl(loopParams, 1, body))

macro parallelForStagedStrided*(loopParams: untyped, stride: Positive, body: untyped): untyped =
  result = getAST(parallelForStagedImpl(loopParams, stride, body))


# Sanity checks
# --------------------------------------------------------

when isMainModule:
  import ./runtime, ./runtime_fsm, ./await_fsm

  block: # global barrier version
    # expandMacros:
    proc sumReduce(n: int): int =
      # expandMacros:
      let res = result.addr
      parallelForStaged i in 0 .. n:
        captures: {res}
        prologue:
          var localSum = 0
        loop:
          localSum += i
        epilogue:
          echo "Thread ", getThreadID(Weave), ": localsum = ", localSum
          res[].atomicInc(localSum)

      syncRoot(Weave)

    init(Weave)
    let sum1M = sumReduce(1000000)
    echo "syncRoot - Sum reduce(0..1000000): ", sum1M
    echo "\n====================================================\n"
    doAssert sum1M == 500_000_500_000
    exit(Weave)

  block: # Awaitable version
    # expandMacros:
    proc sumReduce(n: int): int =
      # expandMacros:
      let res = result.addr
      parallelForStaged i in 0 .. n:
        captures: {res}
        awaitable: paraSum
        prologue:
          var localSum = 0
        loop:
          localSum += i
        epilogue:
          echo "Thread ", getThreadID(Weave), ": localsum = ", localSum
          res[].atomicInc(localSum)

      sync(paraSum)

    init(Weave)
    let sum1M = sumReduce(1000000)
    echo "awaitable loop - Sum reduce(0..1000000): ", sum1M
    doAssert sum1M == 500_000_500_000
    exit(Weave)
