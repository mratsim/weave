# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  # Stdlib
  system/ansi_c, strformat, os, strutils, cpuinfo, math,
  random, locks,
  # Weave
  ../../../weave,
  # 3rd party
  cligen,
  # bench
  ../../wtime, ../../resources

# Helpers
# -------------------------------------------------------

# We need a thin wrapper around raw pointers for matrices,
# Note that matrices for log-sum-exp are usually in the following shapes:
# - Classification of a batch of 256 images in 3 categories: 256x3
# - Classification of a batch of words from a 50000 words dictionary: 256x50000

# Helpers
# -------------------------------------------------------

proc wv_alloc*(T: typedesc): ptr T {.inline.}=
  cast[ptr T](c_malloc(csize_t sizeof(T)))

proc wv_alloc*(T: typedesc, len: SomeInteger): ptr UncheckedArray[T] {.inline.} =
  cast[type result](c_malloc(csize_t len*sizeof(T)))

proc wv_free*[T: ptr](p: T) {.inline.} =
  c_free(p)

# We need a thin wrapper around raw pointers for matrices,
# we can't pass "var" to other threads
type
  Matrix[T: SomeFloat] = object
    buffer: ptr UncheckedArray[T]
    nrows, ncols: int # int64 on x86-64

func newMatrix[T](rows, cols: Natural): Matrix[T] {.inline.} =
  # Create a rows x cols Matrix
  result.buffer = cast[ptr UncheckedArray[T]](c_malloc(csize_t rows*cols*sizeof(T)))
  result.nrows = rows
  result.ncols = cols

template `[]`[T](M: Matrix[T], row, col: Natural): T =
  # row-major storage
  assert row < M.nrows
  assert col < M.ncols
  M.buffer[row * M.ncols + col]

template `[]=`[T](M: Matrix[T], row, col: Natural, value: T) =
  assert row < M.nrows
  assert col < M.ncols
  M.buffer[row * M.ncols + col] = value

proc initialize[T](M: Matrix[T]) =
  randomize(1234) # Seed
  for i in 0 ..< M.nrows:
    for j in 0 ..< M.ncols:
      M[i, j] = T(rand(1.0))

func rowView*[T](M: Matrix[T], rowPos, size: Natural): Matrix[T]{.inline.}=
  ## Returns a new view offset by the row and column stride
  result.buffer = cast[ptr UncheckedArray[T]](
    addr M.buffer[rowPos * M.ncols]
  )
  result.nrows = size
  result.ncols = M.ncols

# Reports
# -------------------------------------------------------

template memUsage(maxRSS, runtimeRSS, pageFaults: untyped{ident}, body: untyped) =
  var maxRSS, runtimeRSS, pageFaults: int32
  block:
    var ru: Rusage
    getrusage(RusageSelf, ru)
    runtimeRSS = ru.ru_maxrss
    pageFaults = ru.ru_minflt

    body

    getrusage(RusageSelf, ru)
    runtimeRSS = ru.ru_maxrss - runtimeRSS
    pageFaults = ru.ru_minflt - pageFaults
    maxRss = ru.ru_maxrss

proc reportConfig(
    scheduler: string,
    nthreads: int, datasetSize, batchSize, imageLabels, textVocabulary: int64
  ) =

  echo "--------------------------------------------------------------------------"
  echo "Scheduler:                                    ", scheduler
  echo "Benchmark:                                    Log-Sum-Exp (Machine Learning) "
  echo "Threads:                                      ", nthreads
  echo "datasetSize:                                  ", datasetSize
  echo "batchSize:                                    ", batchSize
  echo "# of full batches:                            ", datasetSize div batchSize
  echo "# of image labels:                            ", imageLabels
  echo "Text vocabulary size:                         ", textVocabulary

proc reportBench(
    batchSize, numLabels: int64,
    time: float64, maxRSS, runtimeRss, pageFaults: int32,
    logSumExp: float32
  ) =
  echo "--------------------------------------------------------------------------"
  echo "Dataset:                                      ", batchSize,'x',numLabels
  echo "Time(ms):                                     ", round(time, 3)
  echo "Max RSS (KB):                                 ", maxRss
  echo "Runtime RSS (KB):                             ", runtimeRSS
  echo "# of page faults:                             ", pageFaults
  echo "Logsumexp:                                    ", logsumexp

template runBench(procName: untyped, datasetSize, batchSize, numLabels: int64) =
  let data = newMatrix[float32](datasetSize, numLabels)
  data.initialize()

  let start = wtime_msec()

  var lse = 0'f32
  memUsage(maxRSS, runtimeRSS, pageFaults):
    # For simplicity we ignore the last few data points
    for batchIdx in 0 ..< datasetSize div batchSize:
      let X = data.rowView(batchIdx*batchSize, batchSize)
      lse += procName(X)

  let stop = wtime_msec()

  reportBench(batchSize, numlabels, stop-start, maxRSS, runtimeRSS, pageFaults, lse)

# Algo - Serial
# -------------------------------------------------------

proc maxSerial[T: SomeFloat](M: Matrix[T]) : T =
  result = T(-Inf)

  for i in 0 ..< M.nrows:
    for j in 0 ..< M.ncols:
      result = max(result, M[i, j])

proc logsumexpSerial[T: SomeFloat](M: Matrix[T]): T =

  let alpha = M.maxSerial()

  result = 0

  for i in 0 ..< M.nrows:
    for j in 0 ..< M.ncols:
      result += exp(M[i, j] - alpha)

  result = alpha + ln(result)

# Algo - parallel reduction
# -------------------------------------------------------

proc maxWeave[T: SomeFloat](M: Matrix[T]) : T =
  var max: Flowvar[T]

  parallelFor i in 0 ..< M.nrows:
    captures:{M}
    reduce(max):
      prologue:
        var localMax = T(-Inf)
      fold:
        for j in 0 ..< M.ncols:
          localMax = max(localMax, M[i, j])
          # loadBalance(Weave)
      merge(remoteMax):
        localMax = max(localMax, sync(remoteMax))
      return localMax

  result = sync(max)

proc logsumexpWeave[T: SomeFloat](M: Matrix[T]): T =

  let alpha = M.maxWeave()

  var lse: Flowvar[T]

  parallelFor i in 0 ..< M.nrows:
    captures:{alpha, M}
    reduce(lse):
      prologue:
        var localLSE = 0.T
      fold:
        for j in 0 ..< M.ncols:
          localLSE += exp(M[i, j] - alpha)
          # loadBalance(Weave)
      merge(remoteLSE):
        localLSE += sync(remoteLSE)
      return localLSE

  result = alpha + ln(sync(lse))

# Algo - parallel reduction collapsed
# -------------------------------------------------------

proc maxWeaveCollapsed[T: SomeFloat](M: Matrix[T]) : T =
  var max: Flowvar[T]

  parallelFor ij in 0 ..< M.nrows * M.ncols:
    captures:{M}
    reduce(max):
      prologue:
        var localMax = T(-Inf)
      fold:
        localMax = max(localMax, M.buffer[ij])
      merge(remoteMax):
        localMax = max(localMax, sync(remoteMax))
      return localMax

  result = sync(max)

proc logsumexpWeaveCollapsed[T: SomeFloat](M: Matrix[T]): T =

  let alpha = M.maxWeave()

  var lse: Flowvar[T]

  parallelFor ij in 0 ..< M.nrows * M.ncols:
    captures:{alpha, M}
    reduce(lse):
      prologue:
        var localLSE = 0.T
      fold:
        localLSE += exp(M.buffer[ij] - alpha)
      merge(remoteLSE):
        localLSE += sync(remoteLSE)
      return localLSE

  result = alpha + ln(sync(lse))

# Main
# -------------------------------------------------------

proc main(datasetSize = 20000'i64, batchSize = 256'i64, imageLabels = 1000'i64, textVocabulary = 10000'i64) =
  echo "Note that a text vocabulary is often in the 50000-15000 words\n"

  var nthreads: int
  if existsEnv"WEAVE_NUM_THREADS":
    nthreads = getEnv"WEAVE_NUM_THREADS".parseInt()
  else:
    nthreads = countProcessors()

  let sanityM = newMatrix[float32](1, 9)
  for i in 0'i32 ..< 9:
    sanityM[0, i] = i.float32 + 1

  echo "Sanity check, logSumExp(1..<10) should be 9.4585514 (numpy logsumexp): ", logsumexpSerial(sanityM)
  echo '\n'
  wv_free(sanityM.buffer)

  reportConfig("Sequential", 1, datasetSize, batchSize, imageLabels, textVocabulary)

  block:
    runBench(logsumexpSerial, datasetSize, batchSize, imageLabels)
  # block:
  #   runBench(logsumexpSerial, datasetSize, batchSize, textVocabulary)

  const lazy = defined(WV_LazyFlowvar)
  const config = if lazy: " (lazy flowvars)"
                 else: " (eager flowvars)"
  reportConfig("Weave" & config, nthreads, datasetSize, batchSize, imageLabels, textVocabulary)
  init(Weave)

  block:
    runBench(logsumexpWeave, datasetSize, batchSize, imageLabels)
  # block:
  #   runBench(logsumexpWeave, datasetSize, batchSize, textVocabulary)

  reportConfig("Weave (Collapsed)" & config, nthreads, datasetSize, batchSize, imageLabels, textVocabulary)
  block:
    runBench(logsumexpWeaveCollapsed, datasetSize, batchSize, imageLabels)

  exit(Weave)

dispatch(main)
