# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# This file implements a backoff strategy for workers that have nothing to do.
# This is key to avoid burning CPU cycles for nothing and save on power consumption.
#
# There are a couple of areas where backoff can be considered:
# - Sending a steal request
# - Checking incoming steal requests
# - Relaying steal requests
# - Checking incoming tasks
#
# Challenges:
#
# - In Weave, delay in checking and/or relaying steal requests affect all the
#   potential thieves.
#   In other runtimes, a thief that backs off will wake up with 0 task,
#   in Weave it may wake up with 10 steal requests queued.
#
# As each thread as a parent, a thread that backed off can temporarily give up ownership
# of it's steal request channel to its parent instead
#
# ------------------------------------------------------------------
# Backoff strategies
#
# There seems to be 2 main strategies worth exploring:
# - Consider that each processors work as if in a distributed system
#   and reuse research inspired from Wifi/Radio stations, especially
#   on wakeup strategies to limit spurious wakeups.
#   Extensive research is done at the end.
#
# - Augment the relevant channels with a companion MPSC
#   event signaling system.
#   This completely removes spurious wakeups but only applicable
#   for shared memory system.
#
# Extensive research details on distributed backoff
# are provided in the corresponding markdown file

import
  # Standard library
  locks, atomics,
  # Internal
  ../config

type
  EventNotifier* = object
    ## Multi Producers, Single Consumer event notification
    ## This is wait-free for producers and avoid spending time
    ## in expensive kernel land.
    ##
    ## This data structure should be associated with a MPSC channel
    ## to notify that an "event" happened in the channel.
    ## It avoid spurious polling of empty channels,
    ## and allow parking of threads to save on CPU power.
    ##
    ## See also: binary semaphores, eventcount
    ## On Windows: ManuallyResetEvent and AutoResetEvent
    cond{.align: WV_CacheLinePadding.}: Cond
    lock: Lock
    waiting: Atomic[bool]

func initialize*(en: var EventNotifier) =
  en.cond.initCond()
  en.lock.initLock()
  en.waiting.store(false, moRelaxed)

func `=destroy`*(en: var EventNotifier) =
  en.cond.deinitCond()
  en.lock.deinitLock()

func wait*(en: var EventNotifier) {.inline.} =
  ## Wait until we are signaled of an event
  ## Thread is parked and does not consume CPU resources
  assert not en.waiting.load(moRelaxed)

  fence(moRelease)
  en.waiting.store(true, moRelaxed)

  en.lock.acquire()
  while en.waiting.load(moRelaxed):
    fence(moAcquire)
    en.cond.wait(en.lock)
  en.lock.release()

  assert not en.waiting.load(moRelaxed)

func signal*(en: var EventNotifier) {.inline.} =
  ## Signal a thread that it can be unparked

  # No thread waiting, return
  if not en.waiting.load(moRelaxed):
    fence(moAcquire)
    return

  fence(moRelease)
  en.waiting.store(false, moRelaxed)
  en.cond.signal()
