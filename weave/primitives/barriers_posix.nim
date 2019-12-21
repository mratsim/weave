# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Abstractions over OS-specific barrier implementations
# TODO: support Windows (check iOS, Android, Genode, Haiku, Nintendo Switch)

when not compileOption("threads"):
  {.error: "This requires --threads:on compilation flag".}

# Types
# -------------------------------------------------------

when defined(osx):
  import ./barriers_macos
  export PthreadAttr, PthreadBarrier, Errno
else:
  type
    PthreadAttr* {.byref, importc: "pthread_attr_t", header: "<sys/types.h>".} = object
    PthreadBarrier* {.byref, importc: "pthread_barrier_t", header: "<sys/types.h>".} = object

    Errno* = distinct cint

# Pthread
# -------------------------------------------------------
when defined(osx):
  export pthread_barrier_init, pthread_barrier_wait, pthread_barrier_destroy
else:
  proc pthread_barrier_init*(
        barrier: PthreadBarrier,
        attr: PthreadAttr or ptr PthreadAttr,
        count: range[0'i32..high(int32)]
      ): Errno {.header: "<pthread.h>".}
    ## Initialize `barrier` with the attributes `attr`.
    ## The barrier is opened when `count` waiters arrived.

  proc pthread_barrier_destroy*(
        barrier: sink PthreadBarrier): Errno {.header: "<pthread.h>".}
    ## Destroy a previously dynamically initialized `barrier`.

  proc pthread_barrier_wait*(
        barrier: var PthreadBarrier
      ): Errno {.header: "<pthread.h>".}
    ## Wait on `barrier`
    ## Returns PTHREAD_BARRIER_SERIAL_THREAD for a single arbitrary thread
    ## Returns 0 for the other
    ## Returns Errno if there is an error