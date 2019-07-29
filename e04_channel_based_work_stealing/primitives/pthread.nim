# We use raw pthreads to reproduce the Thesis result.
# Nim threads come with additional stack, thread local storage,
# GC management and compat on Windows and Genode platforms

# Note that Nim SysThread == pthread_t in system.nim/threadlocalstorage.nim
# Also we don't use Pthread from the posix standard library as
# it is weakly typed (instead of using distinct types)

{.passC: "-pthread".}
{.passL: "-pthread".}

type
  Pthread* {.importc: "pthread_t", header: "<sys/types.h>".} = distinct uint32
  PthreadAttr* {.importc: "pthread_attr_t", header: "<sys/types.h>".} = object
  PthreadBarrier* {.importc: "pthread_barrier_t",
                      header: "<sys/types.h>".} = object
    abi: array[32 div sizeof(int32), int32]

  Errno* = distinct int32

proc pthread_create*(
       thread: var Pthread,
       attr: ptr PthreadAttr, # In Nim this is a var and how Nim sets a custom stack
       fn: proc (x: pointer): pointer {.thread, noconv.},
       arg: pointer
  ): Errno {.header: "<sys/types.h>".}
  ## Create a new thread
  ## Returns an error code 0 if successful
  ## or an error code described in <errno.h>

proc pthread_barrier_wait*(
       barrier: var PthreadBarrier
     ): Errno {.header: "<sys/types.h>".}
