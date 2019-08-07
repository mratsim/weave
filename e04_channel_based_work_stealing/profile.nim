import
  # Internal
  ./primitives/c,
  ./timer

# Profiling
# ----------------------------------------------------------------------------------

# TODO: use runtime cpu frequency detection
const
  CpuFreqMhz {.intdefine.} = 4100
  CpuFreqGhz = CpuFreqMhz.float64 / 100

template checkName(name: untyped) =
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

template profile_start*(name: untyped) {.dirty.} =
  bind checkName, timer_start
  # checkName(name)
  timer_start(`timer _ name`)

template profile_stop*(name: untyped) {.dirty.} =
  bind checkName, timer_end
  # checkName(name)
  timer_end(`timer _ name`)

template profile*(name, body: untyped): untyped {.dirty.} =
  profile_start(name)
  body
  profile_stop(name)

template profile_results*(): untyped {.dirty.} =
  bind timer_elapsed, tkMicroseconds, timers_elapsed
  # Parsable format
  # The first value should make it easy to grep for these lines, e.g. with
  # ./a.out | grep Timer | cut -d, -f2-
  # Worker ID, Task, Send/Recv Req, Send/Recv Task, Enq/Deq Task, Idle, Total
  printf(
    "Timer,%d,%.3lf,%.3lf,%.3lf,%.3lf,%.3lf,%.3lf\n",
    ID, # Captured from environment
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

  profile_results()

  profile(run_task):
    discard
