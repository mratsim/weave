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
  ./parallel_macros,
  ./contexts,
  ./instrumentation/contracts

when not compileOption("threads"):
  {.error: "This requires --threads:on compilation flag".}

template parallelForWrapper(idx: untyped{ident}, body: untyped): untyped =
  ## To be called within a loop task
  ## Gets the loop bounds and iterate the over them
  ## Also poll steal requests in-between iterations
  let this = myTask()
  ascertain: this.isLoop
  ascertain: this.start == this.cur

  var idx {.inject.} = this.start
  inc this.cur
  while idx < this.stop:
    body
    idx += this.stride
    this.cur += this.stride
    loadBalance(Weave)

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

  # Extract captured variables
  # --------------------------------------------------------
  var captured, capturedTy: NimNode
  if body[0].kind == nnkCall and body[0][0].eqIdent"captures":
    (captured, capturedTy) = extractCaptures(body, 0)

  let CapturedTy = ident"CapturedTy"
  if capturedTy.len > 0:
    result.add quote do:
      type `CapturedTy` = `capturedTy`

  result.addSanityChecks(capturedTy, CapturedTy)

  # Package the body in a proc
  # --------------------------------------------------------
  let parForName = ident"parallelForSection"
  result.add packageParallelFor(
                parForName, bindSym"parallelForWrapper",
                idx, body,
                captured, capturedTy
              )

  # Create the closure environment
  # --------------------------------------------------------
  var fnCall = newCall(parForName)
  let data = ident("data") # typed pointer to data

  if captured.len == 1:
    # With only 1 arg, the tuple syntax doesn't construct a tuple
    # let data = (123) is an int
    fnCall.add nnkDerefExpr.newTree(data)
  else: # This handles the 0 argument case as well
    for i in 0 ..< captured.len:
      fnCall.add nnkBracketExpr.newTree(
        data, newLit i
      )

  # Create the async function (that calls the proc that packages the loop body)
  # --------------------------------------------------------
  let async_fn = ident("weaveParallelFor")
  let withArgs = captured.len > 0

  result.add quote do:
    proc `async_fn`(param: pointer) {.nimcall, gcsafe.} =
      let this = myTask()
      assert not isRootTask(this)

      when bool(`withArgs`):
        let `data` = cast[ptr `CapturedTy`](param)
      `fnCall`

  # Create the task
  # --------------------------------------------------------
  result.addLoopTask(
    async_fn, start, stop, stride, captured, CapturedTy
  )

macro parallelFor*(loopParams: untyped, body: untyped): untyped =
  result = getAST(parallelForImpl(loopParams, 1, body))

macro parallelForStrided*(loopParams: untyped, stride: Positive, body: untyped): untyped =
  result = getAST(parallelForImpl(loopParams, stride, body))

when isMainModule:
  import ./instrumentation/loggers, ./runtime

  block:
    proc main() =
      init(Weave)

      parallelFor i in 0 ..< 100:
        log("%d (thread %d)\n", i, myID())

      exit(Weave)

    echo "Simple parallel for"
    echo "-------------------------"
    # main()
    echo "-------------------------"

  block: # Capturing outside scope
    proc main2() =
      init(Weave)

      var a = 100
      var b = 10
      parallelFor i in 0 ..< 10:
        captures: {a, b}
        log("a+b+i = %d (thread %d)\n", a+i, myID())

      exit(Weave)


    echo "\n\nCapturing outside variables"
    echo "-------------------------"
    # main2()
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
    # main3()
    echo "-------------------------"


  block: # Strided Nested loops
    proc main4() =
      init(Weave)

      expandMacros:
        parallelForStrided i in 0 ..< 100, stride = 30:
          parallelForStrided j in 0 ..< 200, stride = 60:
            captures: {i}
            log("Matrix[%d, %d] (thread %d)\n", i, j, myID())

      exit(Weave)

    echo "\n\nStrided Nested loops"
    echo "-------------------------"
    main4()
    echo "-------------------------"
