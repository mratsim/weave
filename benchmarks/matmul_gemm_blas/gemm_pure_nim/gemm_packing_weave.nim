# Laser
# Copyright (c) 2018 Mamy André-Ratsimbazafy
# Distributed under the Apache v2 License (license terms are at http://www.apache.org/licenses/LICENSE-2.0).
# This file may not be copied, modified, or distributed except according to those terms.

# Due to issue with "static MicroKernel" as parameter
# as of 0.19.9 we pass it as a generic param
#   - 1. undeclared identifier mr/nr, when accessing ukernel
#   - 2. object constructor needs and object type when workaround first issue with macro

import
  ./common/compiler_optim_hints,
  ./common/align_unroller,
  ./common/[gemm_utils, gemm_tiling]

import ../../../weave

withCompilerOptimHints()

# ############################################################
#
#                    Packing A
#
# ############################################################

proc pack_A_mc_kc*[T; ukernel: static MicroKernel](
      packedA: ptr UncheckedArray[T],
      mc, kc: int,
      A: MatrixView[T]) =
  ## Packs panel [kc, mc] into buffer Ã (size ~half-L2 cache)
  ## Pads if needed
  ## Note that A is of shape [M, K] so it is transposed.
  ##
  ## Concretely the outer dimension of packed matrices
  ## is k so that C[i, j] = A[i, k] * B[k, j]
  ## does not require strided access
  let buffer{.restrict.} = assume_aligned packedA
  const MR = ukernel.extract_mr()
  let unroll_stop = mc.round_step_down(MR)

  # 1. Pack m matrices of size kc*mr, m = mc/mr
  parallelForStrided i in 0..< unroll_stop, stride = MR:
    captures: {kc, buffer, A}
    parallelFor k in 0 ..< kc:
      captures: {i, kc, buffer, A}
      for ii in 0 ..< MR:
        buffer[i*kc + k*MR + ii] = A[i+ii, k]

  # 2. Process the tail
  let remainder = mc - unroll_stop
  if remainder > 0:
    let offBuf = buffer + kc*unroll_stop
    for k in 0 ..< kc:
      for i in 0 ..< remainder:
        offBuf[k*MR + i] = A[unroll_stop+i, k]
      for i in remainder ..< MR: # Pad with 0 if packing over the edge
        offBuf[k*MR + i] = 0.T

  sync(Weave)
# ############################################################
#
#                    Packing B
#
# ############################################################

proc pack_B_kc_nc*[T; ukernel: static MicroKernel](
      packedB: ptr UncheckedArray[T],
      kc, nc: int,
      B: MatrixView[T]) =
  ## Packs panel [kc, nc] for ~B (half-L1 cache)
  ## Pads if needed
  ##
  ## Concretely the outer dimension of packed matrices
  ## is k so that C[i, j] = A[i, k] * B[k, j]
  ## does not require strided access
  let buffer{.restrict.} = assume_aligned packedB
  const NR = ukernel.extract_nr()
  let unroll_stop = nc.round_step_down(NR)

  # 1. Pack n matrices of size kc*nr, n = nc/nr
  parallelForStrided j in 0 ..< unroll_stop, stride = NR:
    captures: {kc, buffer, B}
    parallelFor k in 0 ..< kc:
      captures: {j, kc, buffer, B}
      for jj in 0 ..< NR:
        buffer[j*kc + k*NR + jj] = B[k, j+jj]

  # 2. Process the tail
  let remainder = nc - unroll_stop
  if remainder > 0:
    let offBuf = buffer + kc*unroll_stop
    for k in 0 ..< kc:
      for j in 0 ..< remainder:
        offBuf[k*NR + j] = B[k, unroll_stop+j]
      for j in remainder ..< NR: # Pad with 0 if packing over the edge
        offBuf[k*NR + j] = 0.T

  sync(Weave)
