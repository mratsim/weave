
# Time measurements
# ----------------------------------------------------------------------------------

type
  Timer = object
    start, stop: int64
    elapsed: int64
    ghz: float64

  TimerKind = enum
    tkMicroseconds
    tkMilliseconds
    tkSeconds

func cycles_per_sec(t: float64): float64 {.inline.}  = t * 1e9
func cycles_per_msec(t: float64): float64 {.inline.} = t * 1e6
func cycles_per_usec(t: float64): float64 {.inline.} = t * 1e3

when defined(i386 or amd64):
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
	# Thus, use the preferred barrier on the respective CPU, aiming for
	# RDTSCP as the default.
  #
  # From Intel SDM
  # https://www.intel.com/content/dam/www/public/us/en/documents/white-papers/ia-32-ia-64-benchmark-code-execution-paper.pdf
  when not defined(vcc):
    when defined(amd64):
      proc getticks(): int64 {.inline, sideeffect.} =
        var lo, hi: uint64
        # TODO: autodetect RDTSCP support
        #       and use it instead of lfence + RDTSC
        {.emit: """asm volatile(
          "lfence"
          "rdtsc"
          : "=a"(`low`), "=d"(`hi`)
          :
          : "memory"
        );""".}
        return (hi shl 32) or lo
    else:
      proc getticks(): int64 {.inline, sideeffect.} =
        # TODO: autodetect RDTSCP support
        #       and use it instead of lfence + RDTSC
        {.emit: """asm volatile(
          "lfence"
          "rdtsc"
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

func timer_new(timer: var Timer, ghz: float64) {.inline.}=
  timer.elapsed = 0
  timer.ghz = ghz

func timer_reset(timer: var Timer, ghz: float64) {.inline.}=
  timer_new(timer, ghz)

proc timer_start(timer: var Timer) =
  timer.start = getticks()

proc timer_end(timer: var Timer) =
  timer.stop = getticks()
  timer.elapsed += timer.stop - timer.start

func timer_elapsed(timer: Timer, timerKind: TimerKind): float64 =
  case timerKind
  of tkMicroseconds:
    result = timer.elapsed / cycles_per_usec(timer.ghz)
  of tkMilliseconds:
    result = timer.elapsed / cycles_per_msec(timer.ghz)
  of tkSeconds:
    result = timer.elapsed / cycles_per_sec(timer.ghz)
