# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Rectangular matrix multiplication.
#
# Adapted from Cilk 5.4.3 example
#
# https://bradley.csail.mit.edu/svn/repos/cilk/5.4.3/examples/matmul.cilk;
# See the paper ``Cache-Oblivious Algorithms'', by
# Matteo Frigo, Charles E. Leiserson, Harald Prokop, and
# Sridhar Ramachandran, FOCS 1999, for an explanation of
# why this algorithm is good for caches.

import
  # Stdlib
  strformat, os, strutils, math, system/ansi_c,
  cpuinfo,
  # Weave
  ../../weave,
  # bench
  ../wtime, ../resources

# Helpers
# -------------------------------------------------------

# We need a thin wrapper around raw pointers for matrices,
# we can't pass "var" to other threads
type
  Matrix[T: SomeFloat] = object
    buffer: ptr UncheckedArray[T]
    ld: int

func newMatrixNxN[T](n: int): Matrix[T] {.inline.} =
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

func stride*[T](mat: Matrix[T], row, col: Natural): Matrix[T]{.inline.}=
  ## Returns a new view offset by the row and column stride
  result.buffer = cast[ptr UncheckedArray[T]](
    addr mat.buffer[row*mat.ld + col]
  )

func delete[T](mat: sink Matrix[T]) =
  c_free(mat.buffer)

# -------------------------------------------------------

proc xorshiftRand(): uint32 =
  var x {.global.} = uint32(2463534242)
  x = x xor (x shr 13)
  x = x xor (x shl 17)
  x = x xor (x shr 5)
  return x

func zero[T](A: Matrix[T]) =
  # zeroing is not timed
  zeroMem(A.buffer, A.ld * A.ld * sizeof(T))

proc fill[T](A: Matrix[T]) =
  for i in 0 ..< A.ld:
    for j in 0 ..< A.ld:
      A[i, j] = T(xorshiftRand() mod A.ld.uint32)

func maxError(A, B: Matrix): float64 =
  assert A.ld == B.ld
  for i in 0 ..< A.ld:
    for j in 0 ..< A.ld:
      var diff = (A[i, j] - B[i, j]) / A[i, j]
      if diff < 0:
        diff = -diff
      if diff > result:
        result = diff

func check[T](A, B, C: Matrix[T], n: int): bool =
  var
    tr_C = 0.T
    tr_AB = 0.T
  for i in 0 ..< n:
    for j in 0 ..< n:
      tr_AB += A[i, j] * B[j, i]
    tr_C += C[i, i]

  # Note, all benchmarks return false ‾\_(ツ)_/‾
  return abs(tr_AB - tr_C) < 1e-3

proc matmul[T](A, B, C: Matrix[T], m, n, p: int, add: bool): bool =
  # The original bench passes around a ``ld`` parameter (leading dimension?),
  # we store it in the matrices
  # We return a dummy bool to allow waiting on the matmul

  # Threshold
  if (m + n + p) <= 64:
    if add:
      for i in 0 ..< m:
        for k in 0 ..< p:
          var c = 0.T
          for j in 0 ..< n:
            c += A[i, j] * B[j, k]
          C[i, k] += c
    else:
      for i in 0 ..< m:
        for k in 0 ..< p:
          var c = 0.T
          for j in 0 ..< n:
            c += A[i, j] * B[j, k]
          C[i, k] = c

    return

  var h0, h1: FlowVar[bool]
  ## Each half of the computation

  # matrix is larger than threshold
  if m >= n and n >= p:
    let m1 = m shr 1 # divide by 2
    h0 = spawn matmul(A, B, C, m1, n, p, add)
    h1 = spawn matmul(A.stride(m1, 0), B, C.stride(m1, 0), m - m1, n, p, add)
  elif n >= m and n >= p:
    let n1 = n shr 1 # divide by 2
    h0 = spawn matmul(A, B, C, m, n1, p, add)
    h1 = spawn matmul(A.stride(0, n1), B.stride(n1, 0), C, m, n - n1, p, add = true)
  else:
    let p1 = p shr 1
    h0 = spawn matmul(A, B, C, m, n, p1, add)
    h1 = spawn matmul(A, B.stride(0, p1), C.stride(0, p1), m, n, p - p1, add)

  discard sync(h0)
  discard sync(h1)

proc main() =
  var
    n = 3000
    nthreads: int

  if existsEnv"WEAVE_NUM_THREADS":
    nthreads = getEnv"WEAVE_NUM_THREADS".parseInt()
  else:
    nthreads = countProcessors()

  if paramCount() == 0:
    let exeName = getAppFilename().extractFilename()
    echo &"Usage: {exeName} <n (matrix size):{n}>"
    echo &"Running with default config n = {n}"
  elif paramCount() == 1:
    n = paramStr(1).parseInt()
  else:
    let exeName = getAppFilename().extractFilename()
    echo &"Usage: {exeName} <n (matrix size):{n}>"
    echo &"Up to 2 parameters are valid. Received {paramCount()}"
    quit 1

  var A = newMatrixNxN[float32](n)
  var B = newMatrixNxN[float32](n)
  var C = newMatrixNxN[float32](n)

  fill(A)
  fill(B)
  zero(C)

  var ru: Rusage
  getrusage(RusageSelf, ru)
  var
    rss = ru.ru_maxrss
    flt = ru.ru_minflt

  # Staccato benches runtime init and exit as well
  let start = wtime_msec()

  init(Weave)
  discard sync spawn matmul(A, B, C, n, n, n, add = false)
  exit(Weave)

  let stop = wtime_msec()

  const lazy = defined(WV_LazyFlowvar)
  const config = if lazy: " (lazy flowvars)"
                 else: " (eager flowvars)"

  echo "Scheduler:        Weave", config
  echo "Benchmark:        Matrix Multiplication (cache oblivious)"
  echo "Threads:          ", nthreads
  echo "Time(ms)          ", stop - start
  echo "Max RSS (KB):     ", ru.ru_maxrss
  echo "Runtime RSS (KB): ", rss
  echo "# of page faults: ", flt
  echo "Input:            ", n
  echo "Error:           ", check(A, B, C, n)

  delete A
  delete B
  delete C

  quit 0

main()
