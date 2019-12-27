# Apache v2 License
# Mamy Ratsimbazafy

import ./gemm_bench_common, std/strformat

const
  M*     = 16*6*20
  K*     = 16*6*20
  N*     = 16*6*20
  NbSamples* = 300  # This might stresss the allocator when packing if the matrices are big
  CpuGhz = 3.5      # i9-9980XE OC All turbo 4.1GHz (AVX2 4.0GHz, AVX512 3.5GHz)
  NumCpuCores = 18
  VectorWidth = 16  # 8 float32 for AVX2, 16 for AVX512
  InstrCycle = 2    # How many instructions per cycle, (2xFMAs or 1xFMA for example)
  FlopInstr = 2     # How many FLOP per instr (FMAs = 1 add + 1 mul)

  TheoSerialPeak* = CpuGhz * VectorWidth * InstrCycle * FlopInstr
  TheoThreadedPeak* = TheoSerialPeak * NumCpuCores

proc reportConfig*(backend: string, T: type, ashape, bshape: MatrixShape) =
  let req_ops = gemm_required_ops(ashape, bshape)
  let req_bytes = sizeof(T) * gemm_required_data(ashape, bshape)

  let out_shape: MatrixShape = gemm_out_shape(ashape, bshape)
  let out_size = out_shape.M * out_shape.N

  echo ""
  echo "Backend:                        " & backend
  echo "Type:                           " & $T
  echo "A matrix shape:                 " & $ashape
  echo "B matrix shape:                 " & $bshape
  echo "Output shape:                   " & $out_shape
  echo &"Required number of operations: {req_ops.float * 1e-6:>9.3f} millions"
  echo &"Required bytes:                {req_bytes.float * 1e-6:>9.3f} MB"
  echo &"Arithmetic intensity:          {req_ops.float / req_bytes.float:>9.3f} FLOP/byte"
  echo &"Theoretical peak single-core:  {TheoSerialPeak:>9.3f} GFLOP/s"
  echo &"Theoretical peak multi:        {TheoThreadedPeak:>9.3f} GFLOP/s"
