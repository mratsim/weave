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
# when the corresponding checks is deactivated

macro postcondition*(Exc: typedesc[Exception], category: static string, ensure: untyped, errorMsg: string) =
  ## Optional runtime check before returning from a function
  ##
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
  let lineinfo = lineinfoObj(ensure)
  let file = extractFilename(lineinfo.filename)
  let debug = "\n    Contract violated for post-condition at " & file & ":" & $lineinfo.line &
              "\n        " & $ensure.toStrLit &
              "\n    "

  result = quote do:
    when compileOption(`category`):
      if unlikely(not(`ensure`)):
        raise newException(`Exc`, `debug` & `errorMsg`)

# Sanity checks
# ----------------------------------------------------------------------------------

when isMainModule:
  proc assertGreater(x, y: int) =
    postcondition(ValueError, "rangeChecks", x > y, $x & " is not greater than " & $y)

  # We should get a nicely formatted exception
  assertGreater(10, 12)
