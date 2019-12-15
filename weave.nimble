# Package

version       = "0.1.0"
author        = "Mamy André-Ratsimbazafy"
description   = "a state-of-the-art ùultithreading runtime"
license       = "MIT or Apache License 2.0"

# Dependencies

requires "nim >= 1.1.1"

proc test(path: string, lang = "c") =
  if not dirExists "build":
    mkDir "build"
  # Note: we compile in release mode. This still have stacktraces
  #       but is much faster than -d:debug
  echo "\n========================================================================================"
  echo "Running: ", path
  echo "========================================================================================"
  exec "nim " & lang & " --verbosity:0 --hints:off --warnings:off --threads:on -d:release --outdir:build -r " & path

task test, "Run Weave tests":
  test "benchmarks/dfs/weave_dfs.nim"
  test "benchmarks/fibonacci/weave_fib.nim"
  test "benchmarks/heat/weave_heat.nim"
  test "benchmarks/matrix_transposition/weave_transposes.nim"
  test "benchmarks/nqueens/weave_nqueens.nim"
  test "benchmarks/single_task_producer/weave_spc.nim"
