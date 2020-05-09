# Thread Collider
# Copyright (c) 2020 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import ../greenlet/src/greenlet

# Shadow threads
# -----------------------------------------------
# We replace Nim threads by our own "threads" with the same interface

static: doAssert not compileOption("threads"), "Thread Collider requires --threads:off to replace Nim threads"

type
  ThreadState* = enum
    ## Thread state, used for reporting stack traces of interleaved thread status
    # Disabled  # Never scheduled
    Idle        # Schedulable but previous "step" was another thread
    Running     # Schedulable and previous step was this thread
    Parked      # Thread is waiting on a lock or condition variable
    Terminated  # Thread has been joined

  Thread*[TArg] = object
    ## A Thread handle

    # Nim compat
    when TArg is void:
      dataFn: proc () {.nimcall, gcsafe.}
    else:
      dataFn: proc (m: TArg) {.nimcall, gcsafe.}
      data: TArg

    # Collider
    shadow: ShadowThread

  ShadowThread* = ptr object
    ## Collider Metadata for athread

    # Collider
    fiber*: Greenlet   # A fiber to simulate a Nim Thread
    id*: int           # A thread unique ID
    next*: Event       # The next "interesting" event (lock, atomic load, fence, ...)
    state*: State      # The thread state

proc createThread*[TArg](t: var Thread[TArg],
                           tp: proc (arg: TArg) {.thread, nimcall.},
                           param: TArg) =
    ## Creates a new thread `t` and starts its execution.
    ##
    ## Entry point is the proc `tp`. `param` is passed to `tp`.
    ## `TArg` can be ``void`` if you
    ## don't need to pass any data to the thread.
