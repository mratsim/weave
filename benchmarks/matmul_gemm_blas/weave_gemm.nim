# Apache v2 License
# Mamy Ratsimbazafy
#
# GEMM (GEneralized Matrix Multiplication) using Laser, pure Nim + OpenMP
when not compileOption("threads"):
  {.error: "This requires --threads:on compilation flag".}

import
  ./gemm_bench_common, ./gemm_bench_config,
  ./gemm_pure_nim/[gemm_weave, gemm_weave_nestable],
  ../../weave

when not defined(vcc):
  {.pragma: restrict, codegenDecl: "$# __restrict__ $#".}
else:
  {.pragma: restrict, codegenDecl: "$# __restrict $#".}

proc benchWeaveGEMM*(a, b: seq[float32], ashape, bshape: MatrixShape, nb_samples: int): seq[float32] =
  let req_ops = gemm_required_ops(ashape, bshape)
  let out_shape = gemm_out_shape(ashape, bshape)
  let out_size = out_shape.M * out_shape.N

  result = newSeq[float32](out_size)

  let a_ptr{.restrict.} = a[0].unsafeAddr
  let b_ptr{.restrict.} = b[0].unsafeAddr
  let c_ptr{.restrict.} = result[0].addr
  bench("Weave implementation", req_ops):
    # Initialisation, not measured apart for the "Collected n samples in ... seconds"
    zeroMem(result[0].addr, out_size * sizeof(float32)) # We zero memory between computation
  do:
    # Main work
    gemm_strided(
      M, N, K,
      1'f32,  a_ptr, K, 1,       # stride row, stride col
              b_ptr, N, 1,
      0'f32,  c_ptr, N, 1
    )
    syncRoot(Weave) # Weave gemm is async and returns immediately

proc benchWeaveGEMM_nestable*(a, b: seq[float32], ashape, bshape: MatrixShape, nb_samples: int): seq[float32] =
  let req_ops = gemm_required_ops(ashape, bshape)
  let out_shape = gemm_out_shape(ashape, bshape)
  let out_size = out_shape.M * out_shape.N

  result = newSeq[float32](out_size)

  let a_ptr{.restrict.} = a[0].unsafeAddr
  let b_ptr{.restrict.} = b[0].unsafeAddr
  let c_ptr{.restrict.} = result[0].addr
  bench("Weave implementation (nestable in other parallel regions)", req_ops):
    # Initialisation, not measured apart for the "Collected n samples in ... seconds"
    zeroMem(result[0].addr, out_size * sizeof(float32)) # We zero memory between computation
  do:
    # Main work
    gemm_strided_nestable(
      M, N, K,
      1'f32,  a_ptr, K, 1,       # stride row, stride col
              b_ptr, N, 1,
      0'f32,  c_ptr, N, 1
    )
    syncRoot(Weave) # Weave gemm is async and returns immediately

# Bench
when isMainModule:
  import std/[random, sequtils]

  randomize(42) # For reproducibility
  # warmup()
  reportConfig("Weave (Pure Nim)", float32, (M, K), (K, N))

  block:
    let a = newSeqWith(M*K, float32 rand(-0.1..0.1))
    let b = newSeqWith(K*N, float32 rand(-0.1..0.1))

    init(Weave)
    let weave_nestable = benchWeaveGEMM_nestable(a, b, (M,K), (K,N), NbSamples)
    exit(Weave)

    init(Weave)
    let weave = benchWeaveGEMM(a, b, (M,K), (K,N), NbSamples)
    exit(Weave)
