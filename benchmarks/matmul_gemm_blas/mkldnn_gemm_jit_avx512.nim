# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# GEMM (GEneralized Matrix Multiplication) using MKL-DNN / DNNL
# Intel Deep Neural Network Library.

import
  ./gemm_bench_common, ./gemm_bench_config,
  ../vendor/mkldnn


proc benchMKLDNN(a, b: seq[float32], ashape, bshape: MatrixShape, nb_samples: int): seq[float32] =
  let req_ops = gemm_required_ops(ashape, bshape)
  let out_shape = gemm_out_shape(ashape, bshape)
  let out_size = out_shape.M * out_shape.N

  result = newSeq[float32](out_size)
  var # MKL-DNN wants pointers as inputs
    trans = 'N'
    m = int32 M
    n = int32 N
    k = int32 K
    alpha = 1'f32
    lda = int32 K
    ldb = int32 N
    beta = 0'f32
    ldc = int32 N

  bench("Intel MKL-DNN / DNNL JIT AVX512 benchmark", req_ops):
    # Initialisation, not measured apart for the "Collected n samples in ... seconds"
    zeroMem(result[0].addr, out_size * sizeof(float32)) # We zero memory between computation
  do:
    # Main work
    discard mkldnn_jit_avx512_common_gemm_f32(
      trans.addr, trans.addr,
      m.addr, n.addr, k.addr,
      alpha.addr, a[0].unsafeaddr, lda.addr,
                  b[0].unsafeAddr, ldb.addr,
      beta.addr,  result[0].addr, ldc.addr,
                  bias = nil
    )

# Bench
when isMainModule:
  import std/[random, sequtils]

  randomize(42) # FOr reproducibility
  # warmup()
  reportConfig("Intel MKL-DNN JIT AVX512", float32, (M, K), (K, N))

  block:
    let a = newSeqWith(M*K, float32 rand(-0.1..0.1))
    let b = newSeqWith(K*N, float32 rand(-0.1..0.1))

    let mkl = benchMKLDNN(a, b, (M,K), (K,N), NbSamples)
