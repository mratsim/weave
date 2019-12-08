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
  ./datatypes/sync_types, ./contexts,
  ./instrumentation/profilers,
  ./scheduler

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
  #       Ident "a"
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

proc addSanityChecks*(statement, capturedTypes, capturedTypesSym: NimNode) =
  if capturedTypes.len > 0:
    statement.add quote do:
      static:
        doAssert supportsCopyMem(`capturedTypesSym`), "\n\n parallelFor" &
          " has arguments managed by GC (ref/seq/strings),\n" &
          "  they cannot be distributed across threads.\n" &
          "  Argument types: " & $`capturedTypes` & "\n\n"

        doAssert sizeof(`capturedTypesSym`) <= TaskDataSize, "\n\n parallelFor" &
          " has arguments that do not fit in the parallel tasks data buffer.\n" &
          "  Argument types: " & $`capturedTypes` & "\n" &
          "  Current size: " & $sizeof(`capturedTypesSym`) & "\n" &
          "  Maximum size allowed: " & $TaskDataSize & "\n\n"

proc packageParallelFor*(
        procIdent, wrapperTemplate: NimNode,
        prologue, loopBody, epilogue, returnStmt: NimNode,
        idx, env: NimNode,
        capturedVars, capturedTypes: NimNode,
        returnVal = newEmptyNode() # For-loops can return a result in the case of parallel reductions
     ): NimNode =
  # Package a parallel for loop into a proc, it requires:
  # - a proc ident that can be used to call the proc package
  # - a wrapper template, to handle runtime metadata
  # - the loop index and loop body
  # - The captured variables and their types
  # - The return value of the for loop for reductions
  #   or an EmptyNode
  let pragmas = nnkPragma.newTree(
                  ident"nimcall",
                  ident"gcsafe",
                  ident"inline"
                )

  var params = @[returnVal]
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
    prologue, loopBody, epilogue, returnStmt
  )

  result = newProc(
    name = procIdent,
    params = params,
    body = procBody,
    pragmas = pragmas
  )

proc addLoopTask*(statement, asyncFn, start, stop, stride, capturedVars, CapturedTySym: NimNode) =
  ## Add a loop task

  statement.expectKind nnkStmtList
  asyncFn.expectKind nnkIdent

  var withArgs = false
  if not capturedVars.isNil:
    withArgs = true
    capturedVars.expectKind nnkPar
    CapturedTySym.expectKind nnkIdent
    assert capturedVars.len > 0

  statement.add quote do:
    profile(enq_deq_task):
      let task = newTaskFromCache()
      task.parent = myTask()
      task.fn = `async_fn`
      task.isLoop = true
      task.start = `start`
      task.cur = `start`
      task.stop = `stop`
      task.stride = `stride`
      when bool(`withArgs`):
        cast[ptr `CapturedTySym`](task.data.addr)[] = `capturedVars`
      schedule(task)
