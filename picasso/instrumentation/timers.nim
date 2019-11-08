# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Time measurements
# ----------------------------------------------------------------------------------

type
  Timer* = object
    start*, stop*: int64
    elapsed*: int64
    ghz*: float64

  TimerKind* = enum
    tkMicroseconds
    tkMilliseconds
    tkSeconds

func cycles_per_sec(t: float64): float64 {.inline.}  = t * 1e9
func cycles_per_msec(t: float64): float64 {.inline.} = t * 1e6
func cycles_per_usec(t: float64): float64 {.inline.} = t * 1e3

when defined(i386) or defined(amd64):
  # From Linux
  #
  # The RDTSC instruction is not ordered relative to memory
  # access.  The Intel SDM and the AMD APM are both vague on this
  # point, but empirically an RDTSC instruction can be
  # speculatively executed before prior loads.  An RDTSC
  # immediately after an appropriate barrier appears to be
  # ordered as a normal load, that is, it provides the same
  # ordering guarantees as reading from a global memory location
  # that some other imaginary CPU is updating continuously with a
  # time stamp.
  #
  # From Intel SDM
  # https://www.intel.com/content/dam/www/public/us/en/documents/white-papers/ia-32-ia-64-benchmark-code-execution-paper.pdf
  when not defined(vcc):
    when defined(amd64):
      proc getticks(): int64 {.inline.} =
        var lo, hi: int64
        # TODO: Provide a compile-time flag for RDTSCP support
        #       and use it instead of lfence + RDTSC
        {.emit: """asm volatile(
          "lfence\n"
          "rdtsc\n"
          : "=a"(`lo`), "=d"(`hi`)
          :
          : "memory"
        );""".}
        return (hi shl 32) or lo
    else:
      proc getticks(): int64 {.inline.} =
        # TODO: Provide a compile-time flag for RDTSCP support
        #       and use it instead of lfence + RDTSC
        {.emit: """asm volatile(
          "lfence\n"
          "rdtsc\n"
          : "=a"(`result`)
          :
          : "memory"
        );""".}
  else:
    proc rdtsc(): int64 {.sideeffect, importc: "__rdtsc", header: "<intrin.h>".}
    proc lfence() {.importc: "__mm_lfence", header: "<intrin.h>".}

    proc getticks(): int64 {.inline.} =
      lfence()
      return rdtsc()
else:
  {.error: "getticks is not supported on this CPU architecture".}

template timer_new*(timer: var Timer, ghzClock: float64) =
  timer.elapsed = 0
  timer.ghz = ghzClock

template timer_reset(timer: var Timer, ghzClock: float64) =
  timer_new(timer, ghzClock)

template timer_start*(timer: var Timer) =
  timer.start = getticks()

template timer_end*(timer: var Timer) =
  timer.stop = getticks()
  timer.elapsed += timer.stop - timer.start

func timer_elapsed*(timer: Timer, timerKind: TimerKind): float64 {.inline.}=
  case timerKind
  of tkMicroseconds:
    result = timer.elapsed.float64 / cycles_per_usec(timer.ghz)
  of tkMilliseconds:
    result = timer.elapsed.float64 / cycles_per_msec(timer.ghz)
  of tkSeconds:
    result = timer.elapsed.float64 / cycles_per_sec(timer.ghz)

func timers_elapsed*(timers: varargs[Timer],
                    timerKind: TimerKind): float64 {.inline.}=
  for timer in timers:
    result += timer_elapsed(timer, timerKind)
