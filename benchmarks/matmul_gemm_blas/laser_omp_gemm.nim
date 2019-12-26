# Apache v2 License
# Mamy Ratsimbazafy
#
# GEMM (GEneralized Matrix Multiplication) using Laser, pure Nim + OpenMP
{.passC:"-fopenmp".}
{.passL:"-fopenmp".}

import
  ./gemm_bench_common, ./gemm_bench_config,
  ./gemm_pure_nim/gemm_laser_omp

when not defined(vcc):
  {.pragma: restrict, codegenDecl: "$# __restrict__ $#".}
else:
  {.pragma: restrict, codegenDecl: "$# __restrict $#".}

proc benchLaserGEMM(a, b: seq[float32], ashape, bshape: MatrixShape, nb_samples: int): seq[float32] =
  let req_ops = gemm_required_ops(ashape, bshape)
  let out_shape = gemm_out_shape(ashape, bshape)
  let out_size = out_shape.M * out_shape.N

  result = newSeq[float32](out_size)

  let a_ptr{.restrict.} = a[0].unsafeAddr
  let b_ptr{.restrict.} = b[0].unsafeAddr
  let c_ptr{.restrict.} = result[0].addr
  bench("Laser production implementation", req_ops):
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

# Bench
when isMainModule:
  import std/[random, sequtils]

  randomize(42) # FOr reproducibility
  warmup()
  reportConfig("Laser (Pure Nim) + OpenMP", float32, (M, K), (K, N))

  block:
    let a = newSeqWith(M*K, float32 rand(-0.1..0.1))
    let b = newSeqWith(K*N, float32 rand(-0.1..0.1))

    let mkl = benchLaserGEMM(a, b, (M,K), (K,N), NbSamples)
