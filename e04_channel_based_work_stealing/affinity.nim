import
  # Internal
  ./primitives/threads

proc set_thread_affinity*(t: Pthread, cpu: int32) =
  var cpuset {.noinit.}: CpuSet

  cpu_zero(cpuset)
  cpu_set(cpu, cpuset)
  pthread_setaffinity_np(t, sizeof(CpuSet), cpuset)

proc cpu_count*(): int32 {.inline.} =
  var cpuset {.noinit.}: CpuSet

  # The following must be done before any affinity settings
  pthread_getaffinity_np(
    pthread_self(),
    sizeof(CpuSet),
    cpuset
  )

  return cpu_count(cpuset)

# Smoke test
# -------------------------------------------------------

when isMainModule:
  echo cpu_count()
