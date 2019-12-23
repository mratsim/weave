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
  ./contexts,
  ./instrumentation/[contracts, profilers]

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
  var captured, capturedTy: NimNode
  if body[0].kind == nnkCall and body[0][0].eqIdent"captures":
    (captured, capturedTy) = extractCaptures(body, 0)

  let withArgs = capturedTy.len > 0

  let CapturedTy = ident"CapturedTy" # workaround for GC-safe check
  if withArgs:
    result.add quote do:
      type `CapturedTy` = `capturedTy`

  result.addSanityChecks(capturedTy, CapturedTy)

  # Extract the reduction configuration
  # --------------------------------------------------------
  let (prologue, loopBody, epilogue) = extractStagedConfig(body, withArgs)

  # Package the body in a proc
  # --------------------------------------------------------
  let parStagedName = ident"weaveParallelStagedSection"
  let env = ident("weaveParallelStagedSectionClosureEnv_") # typed pointer to data
  result.add packageParallelFor(
                parStagedName, bindSym"parallelStagedWrapper",
                # prologue, loopBody, epilogue,
                prologue, loopBody, epilogue,
                # remoteAccum, return statement
                nil, nil,
                idx, env,
                captured, capturedTy,
                nil
              )

  # Create the async function (that calls the proc that packages the loop body)
  # --------------------------------------------------------
  let parStagedTask = ident("weaveTask_ParallelStaged_")
  var fnCall = newCall(parStagedName)
  if withArgs:
    fnCall.add(env)

  result.add quote do:
    proc `parStagedTask`(param: pointer) {.nimcall, gcsafe.} =
      let this = myTask()
      assert not isRootTask(this)

      when bool(`withArgs`):
        let `env` = cast[ptr `CapturedTy`](param)
      `fnCall`

  # Create the task
  # --------------------------------------------------------
  result.addLoopTask(
    parStagedTask, start, stop, stride, captured, CapturedTy,
    futureIdent = nil, resultFutureType = nil
  )

  # echo result.toStrLit

macro parallelForStaged*(loopParams: untyped, body: untyped): untyped =
  result = getAST(parallelForStagedImpl(loopParams, 1, body))

macro parallelForStagedStrided*(loopParams: untyped, stride: Positive, body: untyped): untyped =
  result = getAST(parallelForStagedImpl(loopParams, stride, body))


# Sanity checks
# --------------------------------------------------------

when isMainModule:
  import ./runtime, ./runtime_fsm

  block:
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

      sync(Weave)

    init(Weave)
    let sum1M = sumReduce(1000000)
    echo "Sum reduce(0..1000000): ", sum1M
    doAssert sum1M == 500_000_500_000
    exit(Weave)
