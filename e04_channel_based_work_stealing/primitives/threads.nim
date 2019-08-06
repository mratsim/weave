# We use raw pthreads to reproduce the Thesis result.
# Nim threads come with additional stack, thread local storage,
# GC management and compat on Windows and Genode platforms

# Note that Nim SysThread == pthread_t in system.nim/threadlocalstorage.nim
# Also we don't use Pthread from the posix standard library as
# it is weakly typed (instead of using distinct types)

# Types
# -------------------------------------------------------

{.passC: "-pthread".}
{.passL: "-pthread".}

# Linux parameters
const CpuSetSize* = 1024
type CpuMaskType = culong

# On BSD CPU_SETSIZE is 256

when defined(debug):
  var Debug_CPU_SETSIZE {.importc: "CPU_SETSIZE", header: "<sched.h>".}: int
  assert Debug_CPU_SETSIZE == CpuSetSize, "Platform is misconfigured"
type
  Pthread* {.importc: "pthread_t", header: "<sys/types.h>".} = distinct culong
  PthreadAttr* {.byref, importc: "pthread_attr_t", header: "<sys/types.h>".} = object
  PthreadBarrier* {.byref, importc: "pthread_barrier_t", header: "<sys/types.h>".} = object

  Errno* = distinct cint

  CpuSet* {.byref, importc: "cpu_set_t", header: "<sched.h>".} = object
    ## A set of CPUs for affinity manipulation.
    ## Implemented as an opaque bitset manipulated by C macros.
    # Always passed by hidden pointer
    when defined(linux) and defined(amd64):
      abi: array[CpuSetSize div (8 * sizeof(CpuMaskType)), CpuMaskType]

# Pthread
# -------------------------------------------------------

proc pthread_create*[T](
       thread: var Pthread,
       attr: ptr PthreadAttr, # In Nim this is a var and how Nim sets a custom stack
       fn: proc (x: ptr T): pointer {.thread, noconv.},
       arg: ptr T
  ): Errno {.header: "<sys/types.h>".}
  ## Create a new thread
  ## Returns an error code 0 if successful
  ## or an error code described in <errno.h>

proc pthread_join*(
       thread: Pthread,
       thread_exit_status: ptr pointer
     ): Errno {.header: "<pthread.h>".}
  ## Make calling thread wait for termination of the `thread`.
  ## The exit status of the thread is stored in `thread_exit_status`,
  ## if `thread_exit_status` is not nil.

proc pthread_self*(): Pthread {.header: "<pthread.h>".}
  ## Obtain the identifier of the current thread

proc pthread_barrier_init*(
       barrier: PthreadBarrier,
       attr: PthreadAttr or ptr PthreadAttr,
       count: range[0'i32..high(int32)]
     ): Errno {.header: "<pthread.h>".}
  ## Initialize `narrier` with the attributes `attr`.
  ## The barrier is opened when `count` waiters arrived.

proc pthread_barrier_destroy*(
       barrier: sink PthreadBarrier): Errno {.header: "<pthread.h>".}
  ## Destroy a previously dynamically initialized `barrier`.

proc pthread_barrier_wait*(
       barrier: var PthreadBarrier
     ): Errno {.header: "<pthread.h>".}
  ## Wait on `barrier`

proc pthread_getaffinity_np*(
       thread: Pthread,
       cpuset_size: csize,
       cpuset: var CpuSet
  ) {.header: "<pthread.h>".}
  ## Get bitset in `cpuset` representing the processors
  ## the thread can run on.

proc pthread_setaffinity_np*(
       thread: Pthread,
       cpuset_size: csize,
       cpuset: CpuSet
  ) {.header: "<pthread.h>".}
  ## Limit specified `thread` to run only on the processors
  ## represented in `cpuset`

# Posix Sched
# -------------------------------------------------------

# Note CpuSet is always passed by (hidden) pointer

proc cpu_zero*(cpuset: var CpuSet) {.importc: "CPU_ZERO", header: "<sched.h>".}
  ## Clears the set so that it contains no CPU
proc cpu_set*(cpu: cint, cpuset: var CpuSet) {.importc: "CPU_SET", header: "<sched.h>".}
  ## Add CPU to set
proc cpu_count*(cpuset: CpuSet): cint {.importc: "CPU_COUNT", header: "<sched.h>".}
  ## Returns the number of CPU in set
proc cpu_isset*(cpu: cint, cpuset: CpuSet) {.importc: "CPU_ISSET", header: "<sched.h>".}
  ## Test to see if `cpu` is a member of `set`.
