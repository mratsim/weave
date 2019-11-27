# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import macros, os, strutils

# A simple design-by-contract API
# ----------------------------------------------------------------------------------

# Everything should be a template that doesn't produce any code
# when WV_Asserts is not defined.
# Those checks are controlled by a custom flag instead of
# "--boundsChecks" or "--nilChecks" to decouple them from user code checks.
# Furthermore, we want them to be very lightweight on performance

# TODO auto-add documentation

proc inspectInfix(node: NimNode): NimNode =
  ## Inspect an expression,
  ## Returns the AST as string with runtime values inlined
  ## from infix operators inlined.
  # TODO: pointer and custom type need a default repr
  #       otherwise we can only resulve simple expressions
  proc inspect(node: NimNode): NimNode =
    case node.kind:
    of nnkInfix:
      return newCall(
          bindSym"&",
          newCall(
            bindSym"&",
            newCall(ident"$", inspect(node[1])),
            newLit(" " & $node[0] & " ")
          ),
          newCall(ident"$", inspect(node[2]))
        )
    of {nnkIdent, nnkSym}:
      return node
    of nnkDotExpr:
      return quote do:
        when `node` is pointer or `node` is ptr:
          toHex(cast[ByteAddress](`node`) and 0xffff_ffff)
        else:
          $(`node`)
    else:
      return node.toStrLit()
  return inspect(node)

macro assertContract(
        checkName: static string,
        predicate: untyped) =
  let lineinfo = lineinfoObj(predicate)
  let file = extractFilename(lineinfo.filename)

  var strippedPredicate: NimNode
  if predicate.kind == nnkStmtList:
    assert predicate.len == 1, "Only one-liner conditions are supported"
    strippedPredicate = predicate[0]
  else:
    strippedPredicate = predicate

  let debug = "\n    Contract violated for " & checkName & " at " & file & ":" & $lineinfo.line &
              "\n        " & $strippedPredicate.toStrLit &
              "\n    The following values are contrary to expectations:" &
              "\n        "
  let values = inspectInfix(strippedPredicate)

  result = quote do:
    when compileOption("assertions"):
      assert(`predicate`, `debug` & $`values` & '\n')
    elif defined(WV_Asserts):
      if unlikely(not(`predicate`)):
        raise newException(AssertionError, `debug` & $`values` & '\n')

# A way way to get the caller function would be nice.

template preCondition*(require: untyped) =
  ## Optional runtime check before returning from a function
  assertContract("pre-condition", require)

template postCondition*(ensure: untyped) =
  ## Optional runtime check at the start of a function
  assertContract("post-condition", ensure)

template ascertain*(check: untyped) =
  ## Optional runtime check in the middle of processing
  assertContract("transient condition", check)

# Sanity checks
# ----------------------------------------------------------------------------------

when isMainModule:
  proc assertGreater(x, y: int) =
    postcondition(x > y)

  # We should get a nicely formatted exception
  assertGreater(10, 12)
