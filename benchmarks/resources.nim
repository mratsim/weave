type
  Timeval {.importc: "timeval", header:"<sys/time.h>", bycopy.} = object

  Rusage* {.importc: "struct rusage", header:"<sys/resource.h>", bycopy.} = object
    ru_utime {.importc.}: Timeval
    ru_stime {.importc.}: Timeval
    ru_maxrss* {.importc.}: int32  # Maximum resident set size
    # ...
    ru_minflt* {.importc.}: int32  # page reclaims (soft page faults)

  RusageWho* {.size: sizeof(cint).} = enum
    RusageChildren = -1
    RusageSelf = 0
    RusageThread = 1

when defined(debug):
  var H_RUSAGE_SELF{.importc, header:"<sys/resource.h".}: cint
  var H_RUSAGE_CHILDREN{.importc, header:"<sys/resource.h".}: cint
  var H_RUSAGE_THREAD{.importc, header:"<sys/resource.h".}: cint
  assert H_RUSAGE_SELF == ord(RusageSelf)
  assert H_RUSAGE_CHILDREN = ord(RusageChildren)
  assert H_RUSAGE_THREAD = ord(RusageThread)

proc getrusage*(who: RusageWho, usage: var Rusage) {.importc, header: "sys/resource.h".}
