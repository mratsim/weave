# Apache v2 License
# Mamy Ratsimbazafy
#
# GEMM (GEneralized Matrix Multiplication) using MKL
# See the .nim.cfg for MKL paths
{.passC:"-fopenmp".}
{.passL:"-fopenmp".}

import ./gemm_bench_common, ./gemm_bench_config

const blas = "mkl_intel_lp64.so"

type
  TransposeType* {.size: sizeof(cint).} = enum
    noTranspose = 111, transpose = 112, conjTranspose = 113
  OrderType* {.size: sizeof(cint).} = enum
    rowMajor = 101, colMajor = 102

proc gemm*(ORDER: OrderType, TRANSA, TRANSB: TransposeType, M, N, K: int, ALPHA: float32,
  A: ptr float32, LDA: int, B: ptr float32, LDB: int, BETA: float32, C: ptr float32, LDC: int)
  {. dynlib: blas, importc: "cblas_sgemm" .}
proc gemm*(ORDER: OrderType, TRANSA, TRANSB: TransposeType, M, N, K: int, ALPHA: float64,
  A: ptr float64, LDA: int, B: ptr float64, LDB: int, BETA: float64, C: ptr float64, LDC: int)
  {. dynlib: blas, importc: "cblas_dgemm" .}

proc benchMKL*(a, b: seq[float32], ashape, bshape: MatrixShape, nb_samples: int): seq[float32] =
  let req_ops = gemm_required_ops(ashape, bshape)
  let out_shape = gemm_out_shape(ashape, bshape)
  let out_size = out_shape.M * out_shape.N

  result = newSeq[float32](out_size)
  bench("Intel MKL benchmark", req_ops):
    # Initialisation, not measured apart for the "Collected n samples in ... seconds"
    zeroMem(result[0].addr, out_size * sizeof(float32)) # We zero memory between computation
  do:
    # Main work
    gemm(
      rowMajor, noTranspose, noTranspose,
      M, N, K,
      1, a[0].unsafeaddr, K,
      b[0].unsafeAddr, N,
      0, result[0].addr, N
    )

# Bench
when isMainModule:
  import std/[random, sequtils]

  randomize(42) # FOr reproducibility
  # warmup()
  reportConfig("Intel MKL", float32, (M, K), (K, N))

  block:
    let a = newSeqWith(M*K, float32 rand(-0.1..0.1))
    let b = newSeqWith(K*N, float32 rand(-0.1..0.1))

    let mkl = benchMKL(a, b, (M,K), (K,N), NbSamples)
