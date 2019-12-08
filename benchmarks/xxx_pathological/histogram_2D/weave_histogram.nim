# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Stdlib
  system/ansi_c, strformat, os, strutils, cpuinfo, math,
  locks,
  # Weave
  ../../weave,
  # 3rd party
  cligen,
  # bench
  ../wtime

# Helpers
# -------------------------------------------------------

# We need a thin wrapper around raw pointers for matrices,
# we can't pass "var" to other threads
type
  Matrix[T: SomeFloat] = object
    buffer: ptr UncheckedArray[T]
    ld: int32

func newMatrixNxN[T](n: int32): Matrix[T] {.inline.} =
  result.buffer = cast[ptr UncheckedArray[T]](c_malloc(csize_t n*n*sizeof(T)))
  result.ld = n

template `[]`[T](mat: Matrix[T], row, col: Natural): T =
  # row-major storage
  assert row < mat.ld
  assert col < mat.ld
  mat.buffer[row * mat.ld + col]

template `[]=`[T](mat: Matrix[T], row, col: Natural, value: T) =
  assert row < mat.ld
  assert col < mat.ld
  mat.buffer[row * mat.ld + col] = value

type
  Histogram = object
    buffer: ptr UncheckedArray[int32]
    len: int32

template `[]`(hist: Histogram, idx: Natural): int32 =
  # row-major storage
  assert idx in 0 ..< hist.len
  hist.buffer[idx]

template `[]=`(hist: Histogram, idx: Natural, value: int32) =
  assert idx in 0 ..< hist.len
  hist.buffer[idx] = value


# -------------------------------------------------------

proc prepareMatrix[T](matrix: var Matrix[T], N: int32) =
  matrix.buffer = wv_alloc(T, N*N)
  matrix.ld = N

  for i in 0 ..< N:
    for j in 0 ..< N:
      matrix[i, j] = 1.0 / T(N) * T(i) * 100

proc newHistogram(bins: int32): Histogram =
  result.buffer = wv_alloc(int32, bins)
  result.len = bins

proc generateHistogram[T](matrix: Matrix[T], hist: Histogram): T =

  # zero-ing the histogram
  for i in 0 ..< hist.len:
    hist[i] = 0

  # Note don't run on borders, they have no neighbour
  for i in 1 ..< matrix.ld-1:
    for j in 1 ..< matrix.ld-1:

      # Sum of cell neigbors
      let sum = abs(matrix[i, j] - matrix[i-1, j]) + abs(matrix[i,j] - matrix[i+1, j]) +
                abs(matrix[i, j] - matrix[i, j-1] + abs(matrix[i, j] - matrix[i, j+1]))

      # Compute index of histogram bin
      let k = int32(sum * T(matrix.ld))
      hist[k] += 1

      # Keep track of the largest element
      if sum > result:
        result = sum

proc generateHistogramWeave[T](matrix: Matrix[T], hist: Histogram): T =

  # We await reduce max only, sending the histogram across threads
  # is too costly so the temporary histogram are freed in their allocating threads
  var distributedMax: Flowvar[T]
  let boxes = hist.len

  for i in 0 ..< boxes:
    hist[i] = 0

  # Parallel reduction
  parallelFor i in 1 ..< matrix.ld-1:
    captures: {hist, matrix, boxes}
    reduce(distributedMax):
      prologue:
        let threadHist = newHistogram(boxes)
        var max = T(-Inf)
      fold:
        # with inner for loop
        for j in 1 ..< matrix.ld-1:
          let sum = abs(matrix[i, j] - matrix[i-1, j]) + abs(matrix[i,j] - matrix[i+1, j]) +
                    abs(matrix[i, j] - matrix[i, j-1] + abs(matrix[i, j] - matrix[i, j+1]))
          let k = int32(sum * T(matrix.ld))

          threadHist[k] += 1
          if sum > max:
            max = sum
      merge(remoteMax):
        block:
          let remoteMax = sync(remoteMax) # Await max from other thread
          if remoteMax > max:
            max = remoteMax
          for k in 0 ..< boxes:
            discard hist[k].addr.atomicFetchAdd(threadHist[k], ATOMIC_RELAXED)
          # wv_free(threadHist.buffer)
      return max

  return sync(distributedMax)

proc main(matrixSize = 25000'i32, boxes = 1000'i32) =

  var matrix: Matrix[float32]
  var hist1 = newHistogram(boxes)
  var hist2 = newHistogram(boxes)

  # The reference code zero-out the histogram in the bench as well
  prepareMatrix(matrix, matrixSize)

  let start = wtime_msec()
  init(Weave)
  let max2 = generateHistogramWeave(matrix, hist2)
  exit(Weave)
  let stop = wtime_msec()

  echo "Time(ms)                                      ", round(stop - start, 3)
  echo "Max:                                          ", max2

dispatch(main)
