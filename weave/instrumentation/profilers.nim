# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# TODO: unused import warning - https://github.com/nim-lang/Nim/issues/11826
when defined(WV_Profile):
  import system/ansi_c, macros, ./timers

# Profiling
# ----------------------------------------------------------------------------------

# TODO: use runtime cpu frequency detection
# This is hard, depends on OS and architecture and varies with processor turbo/freq scaling:
#   - https://stackoverflow.com/questions/8351944/finding-out-the-cpu-clock-frequency-per-core-per-processor
#   - Old paper: http://www.bitmover.com/lmbench/mhz-usenix.pdf
#   - 7z/LZMA technique: https://github.com/jljusten/LZMA-SDK/blob/781863cdf592da3e97420f50de5dac056ad352a5/CPP/7zip/UI/Common/Bench.cpp#L1487-L1506
#   - Loop with carried depency: https://stackoverflow.com/questions/11706563/how-can-i-programmatically-find-the-cpu-frequency-with-c/25400230#25400230
const
  CpuFreqMhz {.intdefine, used.} = 4100
  CpuFreqGhz {.used.} = CpuFreqMhz.float64 / 100

template checkName(name: untyped) {.used.} =
  static:
    if astToStr(name) notin ["run_task", "enq_deq_task", "send_recv_task", "send_recv_req", "idle"]:
      raise newException(
        ValueError,
        "Invalid profile name: \"" & astToStr(name) & "\"\n" &
          """Only "run_task", "enq_deq_task", "send_recv_task", "send_recv_req", "idle" are valid"""
      )

# With untyped dirty templates we need to bind the symbol early
# otherwise they are resolved too late in a scope where they don't exist/
# Alternatively we export ./timer.nim.
when defined(WV_Profile):
  template profile_decl*(name: untyped): untyped {.dirty.} =
    bind checkName, Timer
    checkName(name)
    var `timer _ name`{.inject, threadvar.}: Timer

  template profile_extern_decl*(name: untyped): untyped {.dirty.} =
    bind checkName, Timer
    checkName(name)
    var `timer _ name`*{.inject, threadvar.}: Timer

  template profile_init*(name: untyped) {.dirty.} =
    bind checkName, timer_new, CpuFreqGhz
    # checkName(name)
    timer_new(`timer _ name`, CpuFreqGhz)

  macro profile_start*(name: untyped): untyped =
    let timerName = ident("timer_" & $name)
    # checkName(name)
    result = quote do:
      timer_start(`timerName`)

  macro profile_stop*(name: untyped): untyped =
    let timerName = ident("timer_" & $name)
    # checkName(name)
    result = quote do:
      timer_stop(`timerName`)


  template profile*(name, body: untyped): untyped =
    profile_start(name)
    body
    profile_stop(name)

  template profile_results*(ID: typed): untyped {.dirty.} =
    bind timer_elapsed, tkMicroseconds, timers_elapsed
    # Parsable format
    # The first value should make it easy to grep for these lines, e.g. with
    # ./a.out | grep Timer | cut -d, -f2-
    # Worker ID, Task, Send/Recv Req, Send/Recv Task, Enq/Deq Task, Idle, Total
    c_printf(
      "Timer,%d,%.3lf,%.3lf,%.3lf,%.3lf,%.3lf,%.3lf\n",
      ID,
      timer_elapsed(timer_run_task, tkMicroseconds),
      timer_elapsed(timer_send_recv_req, tkMicroseconds),
      timer_elapsed(timer_send_recv_task, tkMicroseconds),
      timer_elapsed(timer_enq_deq_task, tkMicroseconds),
      timer_elapsed(timer_idle, tkMicroseconds),
      timers_elapsed(
        timer_run_task,
        timer_send_recv_req,
        timer_send_recv_task,
        timer_enq_deq_task,
        timer_idle,
        tkMicroseconds
      )
    )
else:
  template profile_decl*(name: untyped): untyped = discard
  template profile_extern_decl*(name: untyped): untyped = discard
  template profile_init*(name: untyped) = discard
  template profile_start*(name: untyped) = discard
  template profile_stop*(name: untyped) = discard
  template profile*(name, body: untyped): untyped =
    body
  template profile_results*(ID: typed): untyped = discard

# Smoke test
# -------------------------------

when isMainModule:
  let ID = 0

  profile_decl(run_task)
  profile_decl(send_recv_req)
  profile_decl(send_recv_task)
  profile_decl(enq_deq_task)
  profile_decl(idle)

  profile_init(run_task)
  profile_init(send_recv_req)
  profile_init(send_recv_task)
  profile_init(enq_deq_task)
  profile_init(idle)

  profile_results(ID)

  profile(run_task):
    discard
