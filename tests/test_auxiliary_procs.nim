import
  std/[atomics, os],
  ../weave

var count: Atomic[int]

proc increment() = count += 1
proc decrement() = count -= 1

const ThreadsToLaunch = 8 # Arbitrary value

putEnv("WEAVE_NUM_THREADS", $ThreadsToLaunch)

init(Weave, increment)
syncRoot(Weave)
doAssert(count.load == ThreadsToLaunch - 1)
exit(Weave, decrement)
doAssert(count.load == 0)