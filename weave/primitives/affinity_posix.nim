# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Thread primitives
# ----------------------------------------------------------------------------------

type
  Pthread {.importc: "pthread_t", header: "<sys/types.h>".} = distinct culong
  CpuSet {.byref, importc: "cpu_set_t", header: "<sched.h>".} = object

proc pthread_self(): Pthread {.header: "<pthread.h>".}

proc pthread_setaffinity_np(
       thread: Pthread,
       cpuset_size: int,
       cpuset: CpuSet
  ) {.header: "<pthread.h>".}
  ## Limit specified `thread` to run only on the processors
  ## represented in `cpuset`

# Note CpuSet is always passed by (hidden) pointer

proc cpu_zero(cpuset: var CpuSet) {.importc: "CPU_ZERO", header: "<sched.h>".}
  ## Clears the set so that it contains no CPU
proc cpu_set(cpu: cint, cpuset: var CpuSet) {.importc: "CPU_SET", header: "<sched.h>".}
  ## Add CPU to set

# Affinity
# ----------------------------------------------------------------------------------

# Nim doesn't allow the main thread to set its own affinity

proc set_thread_affinity(t: Pthread, cpu: int32) {.inline.}=
  when defined(osx) or defined(android):
    {.warning: "To improve performance we should pin threads to cores.\n" &
                "This is not possible with MacOS or Android.".}
    # Note: on Android it's even more complex due to the Big.Little architecture
    #       with cores with different performance profiles to save on battery
  else:
    var cpuset {.noinit.}: CpuSet

    cpu_zero(cpuset)
    cpu_set(cpu, cpuset)
    pthread_setaffinity_np(t, sizeof(CpuSet), cpuset)

proc pinToCpu*(cpu: int32) {.inline.} =
  ## Set the affinity of the main thread (the calling thread)
  set_thread_affinity(pthread_self(), cpu)
