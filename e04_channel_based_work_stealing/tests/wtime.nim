
import strutils, ospaths
from os import DirSep

const cSourcesPath = currentSourcePath.rsplit(DirSep, 1)[0]
const cHeader = csourcesPath / "wtime.h"

{.passC: "-I" & cSourcesPath .}

proc Wtime_usec*: float64 {.header: cHeader.}
