import
  # Internal
  ./primitives/threads

proc set_thread_affinity*(t: Pthread, cpu: int32) {.inline.}=
  when defined(osx):
    {.warning: "To improve performance we should pin threads to cores.\n" &
                "This is not possible with MacOS.".}
  else:
    var cpuset {.noinit.}: CpuSet

    cpu_zero(cpuset)
    cpu_set(cpu, cpuset)
    pthread_setaffinity_np(t, sizeof(CpuSet), cpuset)

proc set_thread_affinity*(cpu: int32) {.inline.} =
  set_thread_affinity(pthread_self(), cpu)

proc cpu_count(): int32 {.inline.} =
  # Unused - cannot be used on Mac
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
