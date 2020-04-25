# Apache v2 License
# Mamy Ratsimbazafy

import
  std/[random, sequtils],
  ./gemm_bench_common,
  ./gemm_pure_nim/[gemm_weave, gemm_weave_nestable],
  ../../weave

when defined(osx):
  const blas = "libblas.dylib"
else:
  const blas = "libopenblas.so"

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

proc testVsReference*(M, N, K: int) =
  echo "Test [",M,"x",K,"] * [",K,"x",N,"] -> [",M,"x",N,"]"

  let req_ops = gemm_required_ops((M,K), (K,N))
  let out_shape = gemm_out_shape((M,K), (K,N))
  let out_size = out_shape.M * out_shape.N
  let a = newSeqWith(M*K, float32 rand(-0.1..0.1))
  let b = newSeqWith(K*N, float32 rand(-0.1..0.1))

  var result_blas = newSeq[float32](out_size)
  var result_weave = newSeq[float32](out_size)
  var result_weave_nestable = newSeq[float32](out_size)

  block openblas:
    gemm(
      rowMajor, noTranspose, noTranspose,
      M, N, K,
      1, a[0].unsafeaddr, K,
      b[0].unsafeAddr, N,
      0, result_blas[0].addr, N
    )

  block weave:
    gemm_strided(
      M, N, K,
      1'f32,  a[0].unsafeaddr, K, 1,       # stride row, stride col
              b[0].unsafeAddr, N, 1,
      0'f32,  result_weave[0].addr, N, 1
    )
    syncRoot(Weave)

  block weave_nestable:
    gemm_strided_nestable(
      M, N, K,
      1'f32,  a[0].unsafeaddr, K, 1,       # stride row, stride col
              b[0].unsafeAddr, N, 1,
      0'f32,  result_weave_nestable[0].addr, N, 1
    )
    syncRoot(Weave)


  let weaveError = mean_relative_error(result_weave, result_blas)
  let weaveNestableError = mean_relative_error(result_weave_nestable, result_blas)
  echo "  Mean Relative Error of Weave vs reference: ", weaveError
  doAssert weaveError <= 1e-4'f32, $weaveError
  echo "  Mean Relative Error of Weave (nestable) vs reference: ", weaveNestableError
  doAssert weaveNestableError <= 1e-4'f32, $weaveNestableError


when isMainModule:
  randomize(42) # For reproducibility

  const sizes = [2,3,9,37,129,700]

  init(Weave)
  for M in sizes:
    for K in sizes:
      for N in sizes:
        testVsReference(M,N,K)
  exit(Weave)
