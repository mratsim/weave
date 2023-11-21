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
# of its steal request channel to its parent instead
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
#   for shared memory systems.
#
# Extensive research details on distributed backoff
# are provided in the corresponding markdown file
#
# The current file has been formally specified and verified
# Formal specification is available at project_root/formal_verification/event_notifiers.tla

import
  # Standard library
  atomics,
  # Internal
  ../config

when defined(linux):
  import ../primitives/futex_linux
elif defined(windows):
  import ../primitives/futex_windows
else:
  import locks

const supportsFutex = defined(linux) or defined(windows)

# On Linux, Glibc condition variables have lost signal issues
# that do not happen on MacOS.
# Instead we use raw futex to replace both locks and condition variables.
# They uses 20x less space and do not add useless logic for our use case.

type
  EventNotifier* = object
    ## Multi Producers, Single Consumer event notification
    ## This is can be seen as a wait-free condition variable for producers
    ## that avoids them spending time in expensive kernel land due to mutexes.
    ##
    ## This data structure should be associated with a MPSC channel
    ## to notify that an "event" happened in the channel.
    ## It avoid spurious polling of empty channels,
    ## and allow parking of threads to save on CPU power.
    ##
    ## See also: binary semaphores, eventcounts
    ## On Windows: ManuallyResetEvent and AutoResetEvent
    when supportsFutex:
      # ---- Consumer specific ----
      ticket{.align: WV_CacheLinePadding.}: uint8 # A ticket for the consumer to sleep in a phase
      # ---- Contention ---- no real need for padding as cache line should be reloaded in case of contention anyway
      futex: Futex                                # A Futex (atomic int32 that can put thread to sleep)
      phase: Atomic[uint8]                        # A binary timestamp, toggles between 0 and 1 (but there is no atomic "not")
      signaled: Atomic[bool]                      # Signaling condition
    else:
      # ---- Consumer specific ----
      lock{.align: WV_CacheLinePadding.}: Lock # The lock is never used, it's just there for the condition variable
      ticket: uint8                            # A ticket for the consumer to sleep in a phase
      # ---- Contention ---- no real need for padding as cache line should be reloaded in case of contention anyway
      cond: Cond                               # Allow parking of threads
      phase: Atomic[uint8]                     # A binary timestamp, toggles between 0 and 1 (but there is no atomic "not")
      signaled: Atomic[bool]                   # Signaling condition

func initialize*(en: var EventNotifier) {.inline.} =
  when supportsFutex:
    en.futex.initialize()
  else:
    en.cond.initCond()
    en.lock.initLock()
  en.ticket = 0
  en.phase.store(0, moRelaxed)
  en.signaled.store(false, moRelaxed)

when defined(nimAllowNonVarDestructor):
  func `=destroy`*(en: EventNotifier) {.inline.} =
    when not supportsFutex:
      en.cond.deinitCond()
      en.lock.deinitLock()
else:
  func `=destroy`*(en: var EventNotifier) {.inline.} =
    when not supportsFutex:
      en.cond.deinitCond()
      en.lock.deinitLock()

func `=copy`*(dst: var EventNotifier, src: EventNotifier) {.error: "An event notifier cannot be copied".}
func `=sink`*(dst: var EventNotifier, src: EventNotifier) {.error: "An event notifier cannot be moved".}

func prepareToPark*(en: var EventNotifier) {.inline.} =
  ## The consumer intends to sleep soon.
  ## This must be called before the formal notification
  ## via a channel.
  if not en.signaled.load(moRelaxed):
    en.ticket = en.phase.load(moRelaxed)

proc park*(en: var EventNotifier) {.inline.} =
  ## Wait until we are signaled of an event
  ## Thread is parked and does not consume CPU resources
  ## This may wakeup spuriously.
  if not en.signaled.load(moRelaxed):
    if en.ticket == en.phase.load(moRelaxed):
      when supportsFutex:
        en.futex.wait(0)
      else:
        en.cond.wait(en.lock) # Spurious wakeup are not a problem
  en.signaled.store(false, moRelaxed)
  when supportsFutex:
    en.futex.initialize()
  # We still hold the lock but it's not used anyway.

proc notify*(en: var EventNotifier) {.inline.} =
  ## Signal a thread that it can be unparked

  if en.signaled.load(moRelaxed):
    # Another producer is signaling
    return
  en.signaled.store(true, moRelease)
  discard en.phase.fetchXor(1, moRelaxed)
  when supportsFutex:
    en.futex.store(1, moRelease)
    en.futex.wake()
  else:
    en.cond.signal()
