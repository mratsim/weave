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
  ./parallel_macros, ./config,
  ./contexts,
  ./datatypes/flowvars,
  ./instrumentation/[contracts, profilers]

when not compileOption("threads"):
  {.error: "This requires --threads:on compilation flag".}

template parallelReduceWrapper(
  idx: untyped{ident},
  prologue, fold, merge,
  remoteAccum, resultFlowvarType,
  returnStmt: untyped): untyped =
  ## To be called within a loop task
  ## Gets the loop bounds and iterate the over them
  ## Also poll steal requests in-between iterations

  prologue

  block: # Loop body
    let this = myTask()
    ascertain: this.isLoop
    ascertain: this.start == this.cur

    var idx {.inject.} = this.start
    this.cur += this.stride
    while idx < this.stop:
      fold

      idx += this.stride
      this.cur += this.stride
      loadBalance(Weave)

  block: # Merging with flowvars from remote threads
    let this = myTask()
    while not this.futures.isNil:
      let fvNode = cast[FlowvarNode](this.futures)
      this.futures = cast[pointer](fvNode.next)

      LazyFV:
        let remoteAccum = cast[resultFlowvarType](fvNode.lfv)
      EagerFV:
        let remoteAccum = cast[resultFlowvarType](fvNode.chan)

      merge

      # The "sync" in the merge statement should have recycled the flowvar channel already
      # For LazyFlowVar, the LazyFlowvar itself was allocated on the heap, so we need to recycle it as well
      # 2 deallocs for eager FV and 3 for Lazy FV
      recycleFVN(fvNode)

  returnStmt

macro parallelReduceImpl*(loopParams: untyped, stride: int, body: untyped): untyped =
  ## Parallel reduce loop
  ## Syntax:
  ##
  ##   var waitableSum: Flowvar[int]
  ##   parallelFor i in 0 ..< 100:
  ##     reduce(waitableSum):
  ##       prologue:
  ##         ## Initialize before the loop
  ##         var localSum = 0
  ##       fold:
  ##         ## Compute the partial reductions
  ##         localSum += i
  ##       merge(remoteSum):
  ##         ## Merge our local reduction with reduction from remote threads
  ##         ## And return
  ##         localSum += sync(remoteSum)
  ##       return localSum
  ##
  ##   # Await our result
  ##   let sum = sync(waitableSum)
  ##
  ## The first element from the iterator (i) in the example is not available in the prologue.
  ## Depending on multithreaded scheduling it may start at 0 or halfway or close to completion.
  ## The accumulator set in the prologue should be set at the neutral element for your fold operation:
  ## - 0 for addition, 1 for multiplication, +Inf for min, -Inf for max, ...
  ##
  ## In the fold section the iterator i is available, the number of iterations can be cut short
  ## if scheduling the rest on other cores would be faster overall.
  ## - This requires your operation to be associative, i.e. (a+b)+c = a+(b+c).
  ## - It does not require your operation to be commutative (a+b = b+a is not needed).
  ## - In particular floating-point addition is NOT associative due to rounding errors.
  ##   and result may differ between runs.
  ##   For inputs usually in [-1,1]
  ##   the floating point addition error is within 1e-8 (float32) or 1e-15 (float64).
  ##   For inputs beyond 1e^9 please evaluate the acceptable precision.
  ##   Note: that the main benefits of "-ffast-math" is considering floating-point addition
  ##         associative
  ##
  ## In the merge section, an identifier for a partial reduction from a remote core must be passed.
  ## Its type will be a waitable Flowvar of the same type as your local partial reduction
  ## The local partial reduction must be returned.
  ##
  ## Variables from the external scope needs to be explicitly captured.
  ## For example, to compute the variance of a seq in parallel
  ##
  ##    var s = newSeqWith(1000, rand(100.0))
  ##    let mean = mean(s)
  ##
  ##    let ps = cast[ptr UncheckedArray[float64]](s)
  ##    var waitableVariance: Flowvar[float64]
  ##
  ##    parallelFor i in 0 ..< s.len:
  ##      captures: {ps, mean}
  ##      reduce(variance):
  ##        prologue:
  ##          var localVariance = 0.0
  ##        fold:
  ##          localVariance += (ps[i] - mean)^2
  ##        merge(remoteVariance):
  ##          localVariance += sync(remoteVariance)
  ##        return localVariance
  ##
  ##    # Await our result
  ##    let variance = sync(waitableVariance)
  ##
  ## Performance note:
  ##   For trivial floating points operations like addition/sum reduction:
  ##   before parallelizing reductions on multiple cores
  ##   you might try to parallelize it on a single core by
  ##   creating multiple accumulators (between 2 and 4)
  ##   and unrolling the accumulation loop by that amount.
  ##
  ##   The compiler is unable to do that (without -ffast-math)
  ##   as floating point addition is NOT associative and changing
  ##   order will change the result due to floating point rounding errors.
  ##
  ##   The performance improvement is dramatic (2x-3x) as at a low-level
  ##   there is no data dependency between each accumulators and
  ##   the CPU can now use instruction-level parallelism instead
  ##   of suffer from data dependency latency (3 or 4 cycles)
  ##   https://software.intel.com/sites/landingpage/IntrinsicsGuide/#techs=SSE&expand=158
  ##   The reduction becomes memory-bound instead of CPU-latency-bound.
  {.warning: "Parallel reduction is experimental. Speedup compared to serial execution is not guaranteed. It is recommended to use parallelForStaged instead.".}

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
  let (prologue, fold, merge,
      remoteAccum, resultFlowvarType,
      returnStmt, finalAccum) = extractReduceConfig(body, withArgs)

  let FutTy = ident"FutTy" # workaround for GC-safe check
  result.add quote do:
    static: doAssert `finalAccum` is Flowvar
    type `FutTy` = `resultFlowvarType`

  # Package the body in a proc
  # --------------------------------------------------------
  let parReduceName = ident"weaveParallelReduceSection"
  let env = ident("weaveParReduceClosureEnv_") # typed pointer to data
  result.add packageParallelFor(
                parReduceName, bindSym"parallelReduceWrapper",
                # prologue, loopBody, epilogue,
                prologue, fold, merge,
                # remoteAccum, return statement
                remoteAccum, returnStmt,
                idx, env,
                captured, capturedTy,
                FutTy
              )

  # Create the async function (that calls the proc that packages the loop body)
  # --------------------------------------------------------
  let parReduceTask = ident("weaveTask_ParallelReduce_")
  var fnCall = newCall(parReduceName)
  if withArgs:
    fnCall.add(env)

  let fut = ident"future" # will be linked to the finalAccum on the other end

  result.add quote do:
    proc `parReduceTask`(param: pointer) {.nimcall, gcsafe.} =
      let this = myTask()
      assert not isRootTask(this)

      let `fut` = cast[ptr `FutTy`](param)
      when bool(`withArgs`):
        # This requires lazy futures to have a fixed max buffer size
        let offset = cast[pointer](cast[ByteAddress](param) +% sizeof(`FutTy`))
        let `env` = cast[ptr `CapturedTy`](offset)
      let res = `fnCall`
      `fut`[].readyWith(res)

  # Create the task
  # --------------------------------------------------------
  result.addLoopTask(
    parReduceTask, start, stop, stride, captured, CapturedTy,
    finalAccum, FutTy
  )

  # echo result.toStrLit

# Sanity checks
# --------------------------------------------------------


when isMainModule:
  import ./runtime

  block:
    proc sumReduce(n: int): int =
      var waitableSum: Flowvar[int]

      # expandMacros:
      parallelReduceImpl i in 0 .. n, stride = 1:
        reduce(waitableSum):
          prologue:
            var localSum = 0
          fold:
            localSum += i
          merge(remoteSum):
            localSum += sync(remoteSum)
          return localSum

      result = sync(waitableSum)

    init(Weave)
    let sum1M = sumReduce(1000000)
    echo "Sum reduce(0..1000000): ", sum1M
    doAssert sum1M == 500_000_500_000
    exit(Weave)
