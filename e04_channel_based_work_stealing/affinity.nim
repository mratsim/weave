import
  # Internal
  ./primitives/threads

proc cpu_count(): int32 {.inline.} =

  var cpuset {.noinit.}: CpuSet

  # The following must be done before any affinity settings
  pthread_getaffinity_np(
    pthread_self(),
    csize(128),
    cpuset.addr
  )

  return cpu_count(cpuset)

# Smoke test
# -------------------------------------------------------

when isMainModule:
  echo cpu_count()
