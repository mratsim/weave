# Wrapper for Coz, the Causual profiling library
# https://github.com/plasma-umass/coz

import strutils, ospaths
from os import DirSep

const cSourcesPath = currentSourcePath.rsplit(DirSep, 1)[0]
const cHeader = csourcesPath / "coz.h"

{.passC: "-I" & cSourcesPath .}

{.pragma: coz, header: cHeader.}
# type
#   coz_counter_t* {.coz, bycopy.} = object
#     ## Counter info struct, containing both a counter and backoff size
#     count*: cuint
#     backoff*: cuint
#   coz_get_counter_t* {.coz.} = proc(kind: cint, name: cstring): coz_counter_t {.cdecl.}
#     ## The type of the _coz_get_counter function

proc coz_progress_named*(name: cstring) {.importc: "COZ_PROGRESS_NAMED", coz.}
  ## This must be used in a procedure
  ## and cannot be at top-level

# Smoke test
# ----------------------------------------------------------------------------------

when isMainModule:
  proc main() =
    coz_progress_named("task executed")

  main()
