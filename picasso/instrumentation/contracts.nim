# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import strutils, macros, os

# A simple design-by-contract API
# ----------------------------------------------------------------------------------

# Everything should be a template that doesn't produce any code
# when PicassoAsserts is not defined.
# Those checks are controlled by a custom flag instead of
# "--boundsChecks" or "--nilChecks" to decouple them from user code checks.
# Furthermore, we want them to be very lightweight on performance

proc inspectInfix(node: NimNode): NimNode =
  ## Inspect an expression,
  ## Returns the AST as string with runtime values inlined
  ## from infix operators inlined.
  proc inspect(node: NimNode): NimNode =
    case node.kind:
    of nnkInfix:
      return newCall(
          bindSym"&",
          newCall(
            bindSym"&",
            newCall(bindSym"$", inspect(node[1])),
            newLit(" " & $node[0] & " ")
          ),
          newCall(bindSym"$", inspect(node[2]))
        )
    of {nnkIdent, nnkSym}:
      return node
    else:
      return node.toStrLit()
  return inspect(node)

macro assertContract(
        checkName: static string,
        predicate: untyped) =
  ## Available categories:
  ## --objChecks:on|off	turn obj conversion checks on|off
  ## --fieldChecks:on|off	turn case variant field checks on|off
  ## --rangeChecks:on|off	turn range checks on|off
  ## --boundChecks:on|off	turn bound checks on|off
  ## --overflowChecks:on|off	turn int over-/underflow checks on|off
  ## --floatChecks:on|off	turn all floating point (NaN/Inf) checks on|off
  ## --nanChecks:on|off	turn NaN checks on|off
  ## --infChecks:on|off	turn Inf checks on|off
  ## --nilChecks:on|off	turn nil checks on|off
  ## --refChecks:on|off	turn ref checks on|off (only for --newruntime)
  let lineinfo = lineinfoObj(predicate)
  let file = extractFilename(lineinfo.filename)
  let debug = "\n    Contract violated for " & prepost & " at " & file & ":" & $lineinfo.line &
              "\n        " & $predicate.toStrLit &
              "\n    The following values are contrary to expectations:" &
              "\n        "
  let values = inspectInfix(predicate)

  result = quote do:
    when compileOption("assertions"):
      assert(`predicate`, `debug` & `values`)
    elif defined(PicassoAsserts):
      if unlikely(not(`predicate`)):
        raise newException(AssertionError, `debug` & `values`)

template preCondition*(require: untyped) =
  ## Optional runtime check before returning from a function
  assertContract("pre-condition", require)

template postCondition*(ensure: untyped) =
  ## Optional runtime check at the start of a function
  assertContract("post-condition", ensure)

template checkCondition*(check: untyped) =
  ## Optional runtime check in the middle of processing
  assertContract("transient condition", check)

# Sanity checks
# ----------------------------------------------------------------------------------

when isMainModule:
  proc assertGreater(x, y: int) =
    postcondition(x > y)

  # We should get a nicely formatted exception
  assertGreater(10, 12)
