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
  macros, typetraits,
  # Internal
  ./parallel_macros,
  ./scheduler, ./runtime, ./contexts,
  ./datatypes/[sync_types, flowvars],
  ./instrumentation/[contracts, profilers]

when not compileOption("threads"):
  {.error: "This requires --threads:on compilation flag".}

macro parallelReduceImpl(loopParams: untyped, stride: int, body: untyped): untyped =
  ## Parallel for loop
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
  ##         return localSum
  ##
  ##   # Await our result
  ##   let sum = sync(waitableSum)
  ##
  ## Variables from the external scope needs to be explicitly captured.
  ## For example, to compute the variance of a seq in parallel
  ##
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
  ##          return localVariance
  ##
  ##    # Await our result
  ##    let variance = sync(waitableVariance)

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

  let CapturedTy = ident"CapturedTy"
  if withArgs:
    result.add quote do:
      type `CapturedTy` = `capturedTy`

  result.addSanityChecks(capturedTy, CapturedTy)

  # Extract the reduction configuration
  # --------------------------------------------------------
  # The body tree representation is
  #
  # StmtList
  #   Call
  #     Ident "reduce"
  #     Ident "waitableSum"
  #     StmtList
  #       Call
  #         Ident "prologue"
  #         StmtList
  #           VarSection
  #             IdentDefs
  #               Ident "localSum"
  #               Empty
  #               IntLit 0
  #       Call
  #         Ident "fold"
  #         StmtList
  #           Infix
  #             Ident "+="
  #             Ident "localSum"
  #             Ident "i"
  #       Call
  #         Ident "merge"
  #         Ident "remoteSum"
  #         StmtList
  #           Infix
  #             Ident "+="
  #             Ident "localSum"
  #             Call
  #               Ident "sync"
  #               Ident "remoteSum"
  #           ReturnStmt
  #             Ident "localSum"


  let config = if withArgs: body[1] else: body[0]

  config.expectKind(nnkCall)
  doAssert config[0].eqident"reduce"
  config[1].expectKind(nnkIdent)
  config[2].expectKind(nnkStmtList)
  doAssert config[2].len == 3

  let
    prologue = config[2][0]
    fold = config[2][1]
    merge = config[2][2]
    remoteAccumulator = config[2][2][1]

  prologue.expectKind(nnkCall)
  fold.expectKind(nnkCall)
  merge.expectKind(nnkCall)
  remoteAccumulator.expectKind(nnkIdent)
  doAssert prologue[0].eqIdent"prologue"
  doAssert fold[0].eqIdent"fold"
  doAssert merge[0].eqIdent"merge"
  prologue[1].expectKind(nnkStmtList)
  fold[1].expectKind(nnkStmtList)
  merge[1].expectKind(nnkStmtList)


when isMainModule:
  var waitableSum: Flowvar[int]

  parallelReduceImpl i in 0 ..< 100, stride = 1:
    reduce(waitableSum):
      prologue:
        var localSum = 0
      fold:
        localSum += i
      merge(remoteSum):
        localSum += sync(remoteSum)
        return localSum
