# Package

version       = "0.4.9"
author        = "Mamy André-Ratsimbazafy"
description   = "a state-of-the-art ùultithreading runtime"
license       = "MIT or Apache License 2.0"

# Dependencies

# requires Nim post abea80376a113fb218c22b6474727c279e694cd3
requires "nim >= 1.2.0", "synthesis"

proc test(flags, path: string) =
  if not dirExists "build":
    mkDir "build"
  # Note: we compile in release mode. This still have stacktraces
  #       but is much faster than -d:debug

  # Compilation language is controlled by TEST_LANG
  var lang = "c"
  if existsEnv"TEST_LANG":
    lang = getEnv"TEST_LANG"

  echo "\n========================================================================================"
  echo "Running [ ", lang, " ", flags, " ] ", path
  echo "========================================================================================"
  exec "nim " & lang & " " & flags & " --verbosity:0 --hints:off --warnings:off --threads:on -d:release --outdir:build -r " & path

task test, "Run Weave tests":
  test "", "weave/cross_thread_com/channels_spsc_single.nim"
  test "", "weave/cross_thread_com/channels_spsc_single_ptr.nim"
  test "", "weave/cross_thread_com/channels_mpsc_unbounded_batch.nim"
  test "", "weave/cross_thread_com/pledges.nim"

  test "", "weave/datatypes/binary_worker_trees.nim"
  test "", "weave/datatypes/bounded_queues.nim"
  test "", "weave/datatypes/prell_deques.nim"
  test "", "weave/datatypes/sparsesets.nim"

  test "", "weave/memory/lookaside_lists.nim"
  test "", "weave/memory/memory_pools.nim"
  test "", "weave/memory/persistacks.nim"

  test "", "weave/parallel_tasks.nim"
  test "", "weave/parallel_for.nim"
  test "", "weave/parallel_for_staged.nim"
  test "", "weave/parallel_reduce.nim"
  test "", "weave/parallel_jobs.nim"

  test "-d:WV_LazyFlowvar", "weave/parallel_tasks.nim"
  test "-d:WV_LazyFlowvar", "weave/parallel_for.nim"
  test "-d:WV_LazyFlowvar", "weave/parallel_for_staged.nim"
  test "-d:WV_LazyFlowvar", "weave/parallel_reduce.nim"
  test "-d:WV_LazyFlowvar", "weave/parallel_jobs.nim"

  test "", "benchmarks/dfs/weave_dfs.nim"
  test "", "benchmarks/fibonacci/weave_fib.nim"
  test "", "benchmarks/heat/weave_heat.nim"
  test "", "benchmarks/matrix_transposition/weave_transposes.nim"
  test "", "benchmarks/nqueens/weave_nqueens.nim"
  when not defined(windows): # Need "time" support - https://github.com/mratsim/weave/issues/60
    test "", "benchmarks/single_task_producer/weave_spc.nim"
    test "", "benchmarks/bouncing_producer_consumer/weave_bpc.nim"
  when defined(i386) or defined(amd64):
    if not existsEnv"TEST_LANG" or getEnv"TEST_LANG" != "cpp":
      # TODO: syncRoot doesn't block for Pledges - https://github.com/mratsim/weave/issues/97
      # test "", "benchmarks/matmul_gemm_blas/gemm_pure_nim/gemm_weave.nim"
      test "", "benchmarks/matmul_gemm_blas/gemm_pure_nim/gemm_weave_nestable.nim"

  test "-d:WV_LazyFlowvar", "benchmarks/dfs/weave_dfs.nim"
  test "-d:WV_LazyFlowvar", "benchmarks/fibonacci/weave_fib.nim"
  test "-d:WV_LazyFlowvar", "benchmarks/heat/weave_heat.nim"
  test "-d:WV_LazyFlowvar", "benchmarks/matrix_transposition/weave_transposes.nim"
  test "-d:WV_LazyFlowvar", "benchmarks/nqueens/weave_nqueens.nim"
  when not defined(windows): # Timer impl missing
    test "-d:WV_LazyFlowvar", "benchmarks/single_task_producer/weave_spc.nim"
    test "-d:WV_LazyFlowvar", "benchmarks/bouncing_producer_consumer/weave_bpc.nim"
  when defined(i386) or defined(amd64):
    if not existsEnv"TEST_LANG" or getEnv"TEST_LANG" != "cpp":
      # TODO: syncRoot doesn't block for Pledges - https://github.com/mratsim/weave/issues/97
      # test "-d:WV_LazyFlowvar", "benchmarks/matmul_gemm_blas/gemm_pure_nim/gemm_weave.nim"
      test "-d:WV_LazyFlowvar", "benchmarks/matmul_gemm_blas/gemm_pure_nim/gemm_weave_nestable.nim"

  # Full test that combine everything:
  # - Nested parallelFor + parallelStrided
  # - spawn
  # - spawnDelayed by pledges
  # - syncScope
  when not defined(windows) and (defined(i386) or defined(amd64)):
    if not existsEnv"TEST_LANG" or getEnv"TEST_LANG" != "cpp":
      test "-d:danger", "benchmarks/matmul_gemm_blas/test_gemm_output.nim"

task test_gc_arc, "Run Weave tests with --gc:arc":
  test "--gc:arc", "weave/cross_thread_com/channels_spsc_single.nim"
  test "--gc:arc", "weave/cross_thread_com/channels_spsc_single_ptr.nim"
  test "--gc:arc", "weave/cross_thread_com/channels_mpsc_unbounded_batch.nim"
  test "--gc:arc", "weave/cross_thread_com/pledges.nim"

  test "--gc:arc", "weave/datatypes/binary_worker_trees.nim"
  test "--gc:arc", "weave/datatypes/bounded_queues.nim"
  test "--gc:arc", "weave/datatypes/prell_deques.nim"
  test "--gc:arc", "weave/datatypes/sparsesets.nim"

  test "--gc:arc", "weave/memory/lookaside_lists.nim"
  test "--gc:arc", "weave/memory/memory_pools.nim"
  test "--gc:arc", "weave/memory/persistacks.nim"

  test "--gc:arc", "weave/parallel_tasks.nim"
  test "--gc:arc", "weave/parallel_for.nim"
  test "--gc:arc", "weave/parallel_for_staged.nim"
  test "--gc:arc", "weave/parallel_reduce.nim"
  test "--gc:arc", "weave/parallel_jobs.nim"

  test "--gc:arc -d:WV_LazyFlowvar", "weave/parallel_tasks.nim"
  test "--gc:arc -d:WV_LazyFlowvar", "weave/parallel_for.nim"
  test "--gc:arc -d:WV_LazyFlowvar", "weave/parallel_for_staged.nim"
  test "--gc:arc -d:WV_LazyFlowvar", "weave/parallel_reduce.nim"
  test "--gc:arc -d:WV_LazyFlowvar", "weave/parallel_jobs.nim"

  test "--gc:arc", "benchmarks/dfs/weave_dfs.nim"
  test "--gc:arc", "benchmarks/fibonacci/weave_fib.nim"
  test "--gc:arc", "benchmarks/heat/weave_heat.nim"
  test "--gc:arc", "benchmarks/matrix_transposition/weave_transposes.nim"
  test "--gc:arc", "benchmarks/nqueens/weave_nqueens.nim"
  when not defined(windows): # Need "time" support - https://github.com/mratsim/weave/issues/60
    test "--gc:arc", "benchmarks/single_task_producer/weave_spc.nim"
    test "--gc:arc", "benchmarks/bouncing_producer_consumer/weave_bpc.nim"
  when defined(i386) or defined(amd64):
    if not existsEnv"TEST_LANG" or getEnv"TEST_LANG" != "cpp":
      # TODO: syncRoot doesn't block for Pledges - https://github.com/mratsim/weave/issues/97
      # test "--gc:arc", "benchmarks/matmul_gemm_blas/gemm_pure_nim/gemm_weave.nim"
      test "--gc:arc", "benchmarks/matmul_gemm_blas/gemm_pure_nim/gemm_weave_nestable.nim"

  test "--gc:arc -d:WV_LazyFlowvar", "benchmarks/dfs/weave_dfs.nim"
  test "--gc:arc -d:WV_LazyFlowvar", "benchmarks/fibonacci/weave_fib.nim"
  test "--gc:arc -d:WV_LazyFlowvar", "benchmarks/heat/weave_heat.nim"
  test "--gc:arc -d:WV_LazyFlowvar", "benchmarks/matrix_transposition/weave_transposes.nim"
  test "--gc:arc -d:WV_LazyFlowvar", "benchmarks/nqueens/weave_nqueens.nim"
  when not defined(windows): # Timer impl missing
    test "--gc:arc -d:WV_LazyFlowvar", "benchmarks/single_task_producer/weave_spc.nim"
    test "--gc:arc -d:WV_LazyFlowvar", "benchmarks/bouncing_producer_consumer/weave_bpc.nim"
  when defined(i386) or defined(amd64):
    if not existsEnv"TEST_LANG" or getEnv"TEST_LANG" != "cpp":
      # TODO: syncRoot doesn't block for Pledges - https://github.com/mratsim/weave/issues/97
      # test "--gc:arc -d:WV_LazyFlowvar", "benchmarks/matmul_gemm_blas/gemm_pure_nim/gemm_weave.nim"
      test "--gc:arc -d:WV_LazyFlowvar", "benchmarks/matmul_gemm_blas/gemm_pure_nim/gemm_weave_nestable.nim"

  # Full test that combine everything:
  # - Nested parallelFor + parallelStrided
  # - spawn
  # - spawnDelayed by pledges
  # - syncScope
  when not defined(windows) and (defined(i386) or defined(amd64)):
    if not existsEnv"TEST_LANG" or getEnv"TEST_LANG" != "cpp":
      test "-d:danger", "benchmarks/matmul_gemm_blas/test_gemm_output.nim"
