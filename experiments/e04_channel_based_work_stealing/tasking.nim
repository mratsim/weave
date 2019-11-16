import
  ./tasking_internal,
  ./tasking_runtime,
  ./runtime

proc tasking_init*() =
  tasking_internal_init()
  RT_init()
  discard tasking_internal_barrier()

proc tasking_barrier*() =
  Master:
    RT_barrier()

proc tasking_exit*() =

  tasking_internal_exit_signal()

  discard tasking_internal_barrier()
  tasking_internal_statistics()
  RT_exit()
  tasking_internal_exit()
