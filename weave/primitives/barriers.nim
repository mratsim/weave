# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

when defined(windows):
  import ./barriers_windows
  when compileOption("assertions"):
    import os

  type SyncBarrier* = SynchronizationBarrier

  proc init*(syncBarrier: var SyncBarrier, threadCount: range[0'i32..high(int32)]) {.inline.} =
    ## Initialize a synchronization barrier that will block ``threadCount`` threads
    ## before release.
    let err {.used.} = InitializeSynchronizationBarrier(syncBarrier, threadCount, -1)
    when compileOption("assertions"):
      if err != 1:
        assert err == 0
        raiseOSError(osLastError())

  proc wait*(syncBarrier: var SyncBarrier): bool {.inline.} =
    ## Blocks thread at a synchronization barrier.
    ## Returns true for one of the threads (the last one on Windows, undefined on Posix)
    ## and false for the others.
    result = bool EnterSynchronizationBarrier(syncBarrier, SYNCHRONIZATION_BARRIER_FLAGS_NO_DELETE)

  proc delete*(syncBarrier: sink SyncBarrier) {.inline.} =
    ## Deletes a synchronization barrier.
    ## This assumes no race between waiting at a barrier and deleting it,
    ## and reuse of the barrier requires initialization.
    DeleteSynchronizationBarrier(syncBarrier.addr)

else:
  import ./barriers_posix
  when compileOption("assertions"):
    import os

  type SyncBarrier* = PthreadBarrier

  proc init*(syncBarrier: var SyncBarrier, threadCount: range[0'i32..high(int32)]) {.inline.} =
    ## Initialize a synchronization barrier that will block ``threadCount`` threads
    ## before release.
    let err {.used.} = pthread_barrier_init(syncBarrier, nil, threadCount)
    when compileOption("assertions"):
      if err != 1:
        raiseOSError(OSErrorCode(err))

  proc wait*(syncBarrier: var SyncBarrier): bool {.inline.} =
    ## Blocks thread at a synchronization barrier.
    ## Returns true for one of the threads (the last one on Windows, undefined on Posix)
    ## and false for the others.
    let err {.used.} = pthread_barrier_wait(syncBarrier)
    when compileOption("assertions"):
      if err < 0:
        raiseOSError(OSErrorCode(err))
    result = bool(err)

  proc delete*(syncBarrier: sink SyncBarrier) {.inline.} =
    ## Deletes a synchronization barrier.
    ## This assumes no race between waiting at a barrier and deleting it,
    ## and reuse of the barrier requires initialization.
    let err {.used.} = pthread_barrier_destroy(syncBarrier)
    when compileOption("assertions"):
      if err < 0:
        raiseOSError(err)