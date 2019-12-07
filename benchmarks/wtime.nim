
import strutils, os

const cSourcesPath = currentSourcePath.rsplit(DirSep, 1)[0]
const cHeader = csourcesPath / "wtime.h"

{.passC: "-I" & cSourcesPath .}

proc wtime_usec*: float64 {.importc: "Wtime_usec", header: cHeader.}
proc wtime_msec*: float64 {.importc: "Wtime_msec", header: cHeader.}
