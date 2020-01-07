# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Standard library
  macros, typetraits,
  # Internal
  ./datatypes/[sync_types, flowvars], ./contexts,
  ./instrumentation/profilers,
  ./scheduler,
  ./channels/pledges

# Parallel for utilities
# ----------------------------------------------------------

proc rebuildUntyped(loopParams: NimNode): NimNode =
  ## In some cases (generics or static proc) Nim gives us
  ## typed NimNode which are hard to process.
  ## This rebuilds the loopParameters to an untyped AST

  if loopParams.kind == nnkInfix:
    result = loopParams
  else:
    # Instead of
    # ---------------
    # Infix
    #   Ident "in"
    #   Ident "i"
    #   Infix
    #     Ident "..<"
    #     IntLit 0
    #     Ident "n"
    #
    # We received
    # ---------------
    # StmtList
    #   Call
    #     OpenSymChoice
    #       Sym "contains"
    #       Sym "contains"
    #       Sym "contains"
    #     Infix
    #       OpenSymChoice
    #         Sym "..<"
    #         Sym "..<"
    #         Sym "..<"
    #         Sym "..<"
    #         Sym "..<"
    #         Sym "..<"
    #       IntLit 0
    #       Ident "n"
    #     Ident "i"
    loopParams[0].expectKind(nnkCall)
    loopParams[0][0].expectKind(nnkOpenSymChoice)
    assert loopParams[0][0][0].eqIdent"contains"
    loopParams[0][1].expectKind(nnkInfix)
    loopParams[0][1][0].expectKind(nnkOpenSymChoice)

    # Rebuild loopParams
    result = nnkInfix.newTree(
      ident"in",
      loopParams[0][2],
      nnkInfix.newTree(
        ident($loopParams[0][1][0][0]),
        loopParams[0][1][1],
        loopParams[0][1][2]
      )
    )

proc checkLP(loopParams: NimNode) =
  ## Checks loop paremeters
  ## --------------------------------------------------------
  ## loopParams should have the form "i in 0..<10"
  loopParams.expectKind(nnkInfix)
  assert loopParams[0].eqIdent"in"
  loopParams[1].expectKind(nnkIdent)
  loopParams[2].expectKind(nnkInfix) # 0 ..< 10 / 0 .. 10, for now we don't support slice objects
  assert loopParams[2][0].eqIdent".." or loopParams[2][0].eqIdent"..<"

proc extractLP*(loopParams: NimNode): tuple[idx, start, stop: NimNode] =
  ## Extract the index, start and stop of the loop
  ## Strides must be dealt with separately
  let loopParams = rebuildUntyped(loopParams)
  checkLP(loopParams)
  result.idx = loopParams[1]
  result.start = loopParams[2][1]
  result.stop = loopParams[2][2]
  # We use exclusive bounds
  if loopParams[2][0].eqIdent"..":
    result.stop = newCall(ident"+", result.stop, newLit(1))

proc extractCaptures*(body: NimNode, c: int): tuple[captured, capturedTy: NimNode] =
  ## Extract captured variables from the for-loop body.
  ## The capture section is expected at position `c`.
  ## Once extracted the section that declared those captures will be discarded.
  ##
  ## Returns the captured variable and the captured variable types
  ## in a tuple of nnkPar for easy use in tuple construction and destructuring.
  # parallelFor i in 0 ..< 10:
  #   captures: a
  #   ...
  #
  # StmtList
  #   Call
  #     Ident "captures"
  #     StmtList
  #       Curly
  #         Ident "a"
  #   Rest of the body

  body.expectKind(nnkStmtList)
  body[c].expectKind(nnkCall)
  doAssert body[c][0].eqIdent"captures"

  result.captured = nnkPar.newTree()
  result.capturedTy = nnkPar.newTree()

  body[c][1].expectKind(nnkStmtList)
  body[c][1][0].expectKind(nnkCurly)
  for i in 0 ..< body[c][1][0].len:
    result.captured.add body[c][1][0][i]
    result.capturedTy.add newCall(ident"typeof", body[c][1][0][i])

  # Remove the captures section
  body[c] = nnkDiscardStmt.newTree(body[c].toStrLit)

proc extractFutureAndCaptures*(body: NimNode): tuple[future, captured, capturedTy: NimNode] =
  ## Extract the result future/flowvar and the captured variables if any
  ## out of a parallelFor / parallelForStrided / parallelForStaged / parallelForStagedStrided
  ## Returns a future, the captured variable and the captured type
  template findCapturesAwaitable(idx: int) =
    if body[idx][0].eqIdent"captures":
      assert result.captured.isNil and result.capturedTy.isNil, "The captured section can only be set once for a loop."
      (result.captured, result.capturedTy) = extractCaptures(body, idx)
    elif body[idx][0].eqIdent"awaitable":
      body[idx][1].expectKind(nnkStmtList)
      body[idx][1][0].expectKind(nnkIdent)
      assert result.future.isNil, "The awaitable section can only be set once for a loop."
      result.future = body[idx][1][0]
      # Remove the awaitable section
      body[idx] = nnkDiscardStmt.newTree(body[idx].toStrLit)

  for i in 0 ..< body.len-1:
    if body[i].kind == nnkCall:
      findCapturesAwaitable(i)

proc extractPledges*(body: NimNode): NimNode =
  ## Extract the dependencies in/out (pledges) if any
  template findPledges(idx: int) =
    if body[idx][0].eqIdent"dependsOn":
      assert result.isNil, "The dependsOn section can only be set once for a loop."
      result = body[idx][1][0]
      # Remove the dependsOn section
      body[idx] = nnkDiscardStmt.newTree(body[idx].toStrLit)

  for i in 0 ..< body.len-1:
    if body[i].kind == nnkCall:
      findPledges(i)

proc addSanityChecks*(statement, capturedTypes, capturedTypesSym: NimNode) =
  if capturedTypes.len > 0:
    statement.add quote do:
      static:
        # doAssert supportsCopyMem(`capturedTypesSym`), "\n\n parallelFor" &
        #   " has arguments managed by GC (ref/seq/strings),\n" &
        #   "  they cannot be distributed across threads.\n" &
        #   "  Argument types: " & $`capturedTypes` & "\n\n"

        doAssert sizeof(`capturedTypesSym`) <= TaskDataSize, "\n\n parallelFor" &
          " has arguments that do not fit in the parallel tasks data buffer.\n" &
          "  Argument types: " & $`capturedTypes` & "\n" &
          "  Current size: " & $sizeof(`capturedTypesSym`) & "\n" &
          "  Maximum size allowed: " & $TaskDataSize & "\n\n"

proc packageParallelFor*(
        procIdent, wrapperTemplate: NimNode,
        prologue, loopBody, epilogue,
        remoteAccum, returnStmt: NimNode,
        idx, env: NimNode,
        capturedVars, capturedTypes: NimNode,
        resultFvTy: NimNode # For-loops can return a result in the case of parallel reductions
     ): NimNode =
  # Package a parallel for loop into a proc, it requires:
  # - a proc ident that can be used to call the proc package
  # - a wrapper template, to handle runtime metadata
  # - the loop index and loop body
  # - The captured variables and their types
  # - The flowvar wrapped return value of the for loop for reductions
  #   or an EmptyNode
  let pragmas = nnkPragma.newTree(
                  ident"nimcall",
                  ident"gcsafe",
                  ident"inline"
                )

  var params: seq[NimNode]
  if resultFvTy.isNil:
    params.add newEmptyNode()
  else: # Unwrap the flowvar
    params.add nnkDotExpr.newTree(resultFvTy, ident"T")

  var procBody = newStmtList()

  if capturedVars.len > 0:
    params.add newIdentDefs(
      env, nnkPtrTy.newTree(capturedTypes)
    )

    let derefEnv = nnkBracketExpr.newTree(env)
    if capturedVars.len > 1:
      # Unpack the variables captured from the environment
      # let (a, b, c) = env[]
      var unpacker = nnkVarTuple.newTree()
      capturedVars.copyChildrenTo(unpacker)
      unpacker.add newEmptyNode()
      unpacker.add derefEnv

      procBody.add nnkLetSection.newTree(unpacker)
    else:
      procBody.add newLetStmt(capturedVars[0], derefEnv)


  procBody.add newCall(
    wrapperTemplate,
    idx,
    prologue, loopBody, epilogue,
    remoteAccum, resultFvTy, returnStmt
  )

  result = newProc(
    name = procIdent,
    params = params,
    body = procBody,
    pragmas = pragmas
  )

proc addLoopTask*(
    statement, asyncFn,
    start, stop, stride,
    capturedVars, CapturedTySym: NimNode,
    dependsOn: NimNode,
    futureIdent, resultFutureType: NimNode
  ) =
  ## Add a loop task
  ## futureIdent is the final reduction accuulator

  statement.expectKind nnkStmtList
  asyncFn.expectKind nnkIdent

  var withArgs = false
  if not capturedVars.isNil:
    withArgs = true
    capturedVars.expectKind nnkPar
    CapturedTySym.expectKind nnkIdent
    assert capturedVars.len > 0

  let hasFuture = futureIdent != nil
  let futureIdent = if hasFuture: futureIdent
                    else: ident("dummy")

  # Dependencies
  # ---------------------------------------------------
  var scheduleBlock: NimNode
  let task = ident"task"
  if dependsOn.isNil:
    scheduleBlock = newCall(bindSym"schedule", task)
  elif dependsOn.kind == nnkIdent:
    scheduleBlock = quote do:
      if not delayedUntil(`task`, `dependsOn`, myMemPool()):
        schedule(`task`)
  else:
    let (pledge, pledgeIndex) = (dependsOn[0], dependsOn[1])
    if pledgeIndex.kind == nnkIntLit and pledgeIndex.intVal == NoIter:
      scheduleBlock = quote do:
        if not delayedUntil(`task`, `pledge`, myMemPool()):
          schedule(`task`)
    else:
      # This is a dependency on a loop index from ANOTHER loop
      # not the loop that is currently scheduled.
      scheduleBlock = quote do:
        if not delayedUntil(`task`, `pledge`, int32(`pledgeIndex`), myMemPool()):
          schedule(`task`)

  # ---------------------------------------------------
  if hasFuture:
    statement.add quote do:
      when not declared(`futureIdent`):
        var `futureIdent`: `resultFutureType`
      assert not isSpawned(`futureIdent`), "Trying to override an allocated Flowvar."
      `futureIdent` = newFlowvar(myMemPool(), `resultFutureType`.T)

      if likely(`stop`-`start` != 0):
        when defined(WV_profile):
          # TODO profiling templates visibility issue
          timer_start(timer_enq_deq_task)
        block enq_deq_task:
          let `task` = newTaskFromCache()
          `task`.parent = myTask()
          `task`.fn = `asyncFn`

          `task`.start = `start`
          `task`.cur = `start`
          `task`.stop = `stop`
          `task`.stride = `stride`
          
          `task`.futureSize = uint8(sizeof(`resultFutureType`.T))
          `task`.hasFuture = true
          `task`.isLoop = true
          `task`.isInitialIter = true
          when bool(`withArgs`):
            cast[ptr (`resultFutureType`, `CapturedTySym`)](`task`.data.addr)[] = (`futureIdent`, `capturedVars`)
          else:
            cast[ptr `resultFutureType`](`task`.data.addr)[] = `futureIdent`
          `scheduleBlock`
          when defined(WV_profile):
            timer_stop(timer_enq_deq_task)
      else:
        `futureIdent`.readyWith(default(`resultFutureType`.T))
  else:
    statement.add quote do:
      if likely(`stop`-`start` != 0):
        when defined(WV_profile):
          # TODO profiling templates visibility issue
          timer_start(timer_enq_deq_task)
        block enq_deq_task:
          let `task` = newTaskFromCache()
          `task`.parent = myTask()
          `task`.fn = `asyncFn`
          `task`.isLoop = true
          `task`.start = `start`
          `task`.cur = `start`
          `task`.stop = `stop`
          `task`.stride = `stride`
          when bool(`withArgs`):
            cast[ptr `CapturedTySym`](`task`.data.addr)[] = `capturedVars`
          `scheduleBlock`
          when defined(WV_profile):
            timer_stop(timer_enq_deq_task)

type Example = enum
  Reduce
  Staged

template parReduceExample() {.dirty.}=
  # Used for a nice error message

  proc parallelReduceExample(n: int): int =

    ## First declare the future/flowvar that will
    ## hold the reduction result
    var waitableSum: Flowvar[int]

    ## Then describe the reduction loop
    parallelFor i in 0 ..< n, stride = 1:
      ## stride is optional
      reduce(waitableSum):
        prologue:
          ## Declare your local reduction variable(s) here
          ## It should be initialize with the neutral element
          ## corresponding to your fold operation.
          ## (0 for addition, 1 for multiplication, -Inf for max, +Inf for min, ...)
          var localSum = 0
        fold:
          ## This is the reduction loop
          localSum += i
        merge(remoteSum):
          ## Define how to merge with partial reduction from remote threads
          localSum += sync(remoteSum)
        ## Return your local partial reduction
        return localSum

    ## Await the parallel reduction
    return sync(waitableSum)

template parStagedExample() {.dirty.} =
  # Used for a nice error message

  proc parallelStagedSumExample(n: int): int =
    ## We will do a sum reduction to illustrate
    ## staged parallel for

    ## First take the address of the result
    let res = result.addr

    ## Then describe the reduction loop
    parallelForStaged i in 0 .. n:
      ## stride is optional
      captures: {res}
      awaitable: myParallelLoop
      prologue:
        ## Declare anything needed before the for-loop
        ## This will be thread-local, so each thread will run this section idnependently.
        ## The loop increment is not available here
        var localSum = 0
      loop:
        ## This is the parallel loop
        localSum += i
      epilogue:
        ## Once the loop is finished, you have a final opportunity for processing.
        ## Thread-local cleanup should happen here as well
        ## Here we print the localSum and atomically increment the global sum
        ## before ending the task.
        echo "Thread ", getThreadID(Weave), ": localsum = ", localSum
        res[].atomicInc(localSum)

    ## Await the parallel reduction
    return sync(waitableSum)

proc printReduceExample() =
  let example = getAst(parReduceExample())
  echo example.toStrLit()
proc printStagedExample() =
  let example = getAst(parStagedExample())
  echo example.toStrLit()

proc testKind(nn: NimNode, nnk: NimNodeKind, kind: Example) =
  if nn.kind != nnk:
    case kind
    of Reduce: printReduceExample()
    of Staged: printStagedExample()
    nn.expectKind(nnk) # Gives nice line numbers

proc extractReduceConfig*(body: NimNode, withArgs: bool): tuple[
    prologue, fold, merge,
    remoteAccum, resultFlowvarType,
    returnStmt, finalAccum: NimNode
  ] =
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
  #       ReturnStmt
  #         Ident "localSum"
  let config = if withArgs: body[1] else: body[0]
  doAssert config[0].eqident"reduce"

  config.testKind(nnkCall, Reduce)
  config[1].testKind(nnkIdent, Reduce)
  config[2].testKind(nnkStmtList, Reduce)

  if config[2].len != 4:
    printReduceExample()
    error "A reduction should have 4 sections named: prologue, fold, merge and a return statement"

  let
    finalAccum = config[1]
    resultFvTy = newCall(ident"typeof", finalAccum)
    prologue = config[2][0]
    fold = config[2][1]
    merge = config[2][2]
    remoteAccum = merge[1]
    returnStmt = config[2][3]

  # Sanity checks
  prologue.testKind(nnkCall, Reduce)
  fold.testKind(nnkCall, Reduce)
  merge.testKind(nnkCall, Reduce)
  remoteAccum.testKind(nnkIdent, Reduce)
  returnStmt.testKind(nnkReturnStmt, Reduce)
  if not (prologue[0].eqIdent"prologue" and fold[0].eqIdent"fold" and merge[0].eqIdent"merge"):
    printReduceExample()
    error "A reduction should have 4 sections named: prologue, fold, merge and a return statement"
  prologue[1].testKind(nnkStmtList, Reduce)
  fold[1].testKind(nnkStmtList, Reduce)
  merge[2].testKind(nnkStmtList, Reduce)

  result = (prologue[1], fold[1], merge[2],
            remoteAccum, resultFvTy,
            returnStmt, finalAccum)

proc extractStagedConfig*(body: NimNode, withArgs, awaitable: bool): tuple[
    prologue, loopBody, epilogue: NimNode
  ] =
  # The body tree representation is
  #
  # StmtList
  #   Call
  #     Ident "prologue"
  #     StmtList
  #       VarSection
  #         IdentDefs
  #           Ident "localSum"
  #           Empty
  #           IntLit 0
  #   Call
  #     Ident "loop"
  #     StmtList
  #       Infix
  #         Ident "+="
  #         Ident "localSum"
  #         Ident "i"
  #   Call
  #     Ident "epilogue"
  #     StmtList
  #       (increment of the result variable)

  # Offset by the captures and awaitable section
  let idx = int(withArgs) + int(awaitable)

  if body.len != idx + 3:
    printStagedExample()
    error "A staged for loop should have 3 sections named: prologue, loop and epilogue"

  let
    prologue = body[idx]
    loop = body[idx+1]
    epilogue = body[idx+2]

  # Sanity checks
  prologue.testKind(nnkCall, Staged)
  loop.testKind(nnkCall, Staged)
  epilogue.testKind(nnkCall, Staged)
  if not (prologue[0].eqIdent"prologue" and loop[0].eqIdent"loop" and epilogue[0].eqIdent"epilogue"):
    printStagedExample()
    error "A staged for loop should have 3 sections named: prologue, loop and epilogue"
  prologue[1].testKind(nnkStmtList, Staged)
  loop[1].testKind(nnkStmtList, Staged)
  epilogue[1].testKind(nnkStmtList, Staged)

  result = (prologue[1], loop[1], epilogue[1])
