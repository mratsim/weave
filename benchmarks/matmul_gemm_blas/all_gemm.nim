# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ./laser_omp_gemm,
  ./mkl_gemm, # OpenBLAS nd MKL cannot be linked at the same time
  ./weave_gemm,
  ./gemm_bench_common,
  ./gemm_bench_config,
  ../../weave

# This aggregate all benchmarks in one
# Warning: Bench results are not reliable, it seems like threads/calls
# interfere with each other, even when only calling OpenMP-based code.

when isMainModule:
  import std/[random, sequtils]

  randomize(42) # For reproducibility

  let a = newSeqWith(M*K, float32 rand(-0.1..0.1))
  let b = newSeqWith(K*N, float32 rand(-0.1..0.1))

  warmup()
  echo "Warning: The aggregate bench is unreliable, the libraries interfere with each other."

  block:
    reportConfig("Intel MKL + Laser OMP + Weave", float32, (M, K), (K, N))
    let mkl = benchMKL(a, b, (M,K), (K,N), NbSamples)

    # let laser = benchLaserGEMM(a, b, (M,K), (K,N), NbSamples)

    init(Weave)
    let weave = benchWeaveGEMM(a, b, (M,K), (K,N), NbSamples)
    exit(Weave)

    let weaveError = mean_relative_error(weave, mkl)
    echo "Mean Relative Error of Weave vs reference: ", weaveError
    doAssert weaveError <= 1e-5'f32, $weaveError

    # let laserError = mean_relative_error(laser, mkl)
    # echo "Mean Relative Error of Laser vs reference: ", laserError
    # doAssert laserError <= 1e-5'f32, $laserError
