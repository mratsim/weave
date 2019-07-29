from strutils import parseEnum

# TODO: document compilation flags

type
  StealKind {.pure.}= enum
    one
    half
    adaptative

  SplitKind {.pure.}= enum
    half
    guided
    adaptative

const
  Platform{.strdefine.} = "SHM"
  Steal{.strdefine.} = "one"
  Split{.strdefine.} = "half"

  StealStrategy = parseEnum[StealKind](Steal)
  SplitStrategy = parseEnum[SplitKind](Split)

when Platform == "SHM":
  {.pragma: private, threadvar.}
elif Platform == "SCC":
  {.pragma: private.}
else:
  static:
    echo "Invalid platform \"", Platform &
      "\". Only SHM (Shared Memory) and SCC (Intel Single Chip Cloud experimental CPU) " &
      "are supported"
