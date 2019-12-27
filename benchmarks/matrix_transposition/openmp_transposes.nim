# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Original transposition codes from Laser project
# (c) Mamy André Ratsimbazafy, Apache  License version 2

import
  # Stdlib
  strformat, os, strutils, math, system/ansi_c,
  cpuinfo, streams, strscans,
  # Third-party
  cligen,
  # bench
  ../wtime, ../resources

# OpenMP
# ---------------------------------------------------

{.passC:"-fopenmp".}
{.passL:"-fopenmp".}
{.pragma: omp, header:"omp.h".}
proc omp_get_num_threads*(): cint {.omp.}

# Memory
# ---------------------------------------------------

proc wv_alloc*(T: typedesc): ptr T {.inline.}=
  ## Default allocator for the Picasso library
  ## This allocates memory to hold the type T
  ## and returns a pointer to it
  ##
  ## Can use Nim allocator to measure the overhead of its lock
  ## Memory is not zeroed
  when defined(WV_useNimAlloc):
    createSharedU(T)
  else:
    cast[ptr T](c_malloc(csize_t sizeof(T)))

proc wv_alloc*(T: typedesc, len: SomeInteger): ptr UncheckedArray[T] {.inline.} =
  ## Default allocator for the Picasso library.
  ## This allocates a contiguous chunk of memory
  ## to hold ``len`` elements of type T
  ## and returns a pointer to it.
  ##
  ## Can use Nim allocator to measure the overhead of its lock
  ## Memory is not zeroed
  when defined(WV_useNimAlloc):
    cast[type result](createSharedU(T, len))
  else:
    cast[type result](c_malloc(csize_t len*sizeof(T)))

proc wv_free*[T: ptr](p: T) {.inline.} =
  when defined(WV_useNimAlloc):
    freeShared(p)
  else:
    c_free(p)

# Transpose implementations
# ---------------------------------------------------

type TransposeStrategy = enum
  Sequential
  Naive
  Collapsed
  TiledCollapsed

# Question: do we need __restrict to avoid the compiler generating
#           defensive aliasing robust code?

proc sequentialTranspose(M, N: int, bufIn, bufOut: ptr UncheckedArray[float32]) =
  for j in 0 ..< N:
    for i in 0 ..< M:
      bufOut[j*M+i] = bufIn[i*N+j]

proc ompNaiveTranspose(M, N: int, bufIn, bufOut: ptr UncheckedArray[float32]) =
  ## Transpose a MxN matrix into a NxM matrix

  # Write are more expensive than read so we keep i accesses linear for writes
  {.push stacktrace:off.}
  for j in 0||(N-1):
    for i in 0 ..< M:
      bufOut[j*M+i] = bufIn[i*N+j]
  {.pop.}

proc ompCollapsedTranspose(M, N: int, bufIn, bufOut: ptr UncheckedArray[float32]) =
  ## Transpose a MxN matrix into a NxM matrix

  # We need to go down to C level for the collapsed clause
  # This relies on M, N, bfIn, bufOut symbols being the same in C and Nim
  # The proper interpolation syntax is a bit busy otherwise
  {.emit: """

  #pragma omp parallel for collapse(2)
  for (int i = 0; i < `M`; ++i)
    for (int j = 0; j < `N`; ++j)
      `bufOut`[j*M+i] = `bufIn`[i*N+j];
  """.}

proc omp2DTiledCollapsedTranspose(M, N: int, bufIn, bufOut: ptr UncheckedArray[float32]) =
  ## Transpose with 2D tiling and collapsed

  const blck = 64

  {.emit: """

  #define min(a,b) (((a)<(b))?(a):(b))

  #pragma omp parallel for collapse(2)
  for (int j = 0; j < `N`; j+=`blck`)
    for (int i = 0; i < `M`; i+=`blck`)
      for (int jj = j; jj<j+`blck` && jj<`N`; jj++)
        for (int ii = i; ii<min(i+`blck`,`M`); ii++)
          `bufOut`[ii+jj*`M`] = `bufIn`[jj+ii*`N`];
  """.}


# Meta
# ---------------------------------------------------

func computeMeta(height, width: int): tuple[reqOps, reqBytes, bufSize: int] =

  result.reqOps = height * width
  result.reqBytes = sizeof(float32) * height * width
  result.bufSize = height * width

func initialize(buffer: ptr UncheckedArray[float32], len: int) =
  for i in 0 ..< len:
    buffer[i] = i.float32

# Bench
# ---------------------------------------------------

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

proc report(
    M, N: int, nthreads: int32, nrounds: int, reordered: bool,
    transposeStrategy: TransposeStrategy, reqOps, reqBytes: int,
    mxnTime: float64, mxnMaxRSS, mxnRuntimeRss, mxnPageFaults: int32,
    nxmTime: float64, nxmMaxRSS, nxmRuntimeRss, nxmPageFaults: int32,
  ) =

  let arithIntensity = reqOps.float / reqBytes.float
  let mxnPerf = reqOps.float/(mxnTime*1e-3 / nrounds.float) * 1e-9 # Gops per second
  let nxmPerf = reqOps.float/(nxmTime*1e-3 / nrounds.float) * 1e-9 # Gops per second

  echo "--------------------------------------------------------------------------"
  echo "Scheduler:                                    OpenMP"
  echo "Benchmark:                                    Transpose - ", $transposeStrategy
  echo "Threads:                                      ", nthreads
  echo "# of rounds:                                  ", nrounds
  echo "# of operations:                              ", reqOps
  echo "# of bytes:                                   ", reqBytes
  echo "Arithmetic Intensity:                         ", round(arithIntensity, 3)
  echo "--------------------------------------------------------------------------"
  if not reordered:
    echo "Transposition:                                ", M,'x',N, " --> ", N, 'x', M
    echo "Time(ms):                                     ", round(mxnTime, 3)
    echo "Max RSS (KB):                                 ", mxnMaxRss
    echo "Runtime RSS (KB):                             ", mxnRuntimeRSS
    echo "# of page faults:                             ", mxnPageFaults
    echo "Perf (GMEMOPs/s ~ GigaMemory Operations/s)    ", round(mxnPerf, 3)
    echo "--------------------------------------------------------------------------"
    echo "Transposition:                                ", N,'x',M, " --> ", M, 'x', N
    echo "Time(ms):                                     ", round(nxmTime, 3)
    echo "Max RSS (KB):                                 ", nxmMaxRss
    echo "Runtime RSS (KB):                             ", nxmRuntimeRSS
    echo "# of page faults:                             ", nxmPageFaults
    echo "Perf (GMEMOPs/s ~ GigaMemory Operations/s)    ", round(nxmPerf, 3)
  else:
    echo "Transposition:                                ", N,'x',M, " --> ", M, 'x', N
    echo "Time(ms):                                     ", round(nxmTime, 3)
    echo "Max RSS (KB):                                 ", nxmMaxRss
    echo "Runtime RSS (KB):                             ", nxmRuntimeRSS
    echo "# of page faults:                             ", nxmPageFaults
    echo "Perf (GMEMOPs/s ~ GigaMemory Operations/s)    ", round(mxnPerf, 3)
    echo "--------------------------------------------------------------------------"
    echo "Transposition:                                ", M,'x',N, " --> ", N, 'x', M
    echo "Time(ms):                                     ", round(mxnTime, 3)
    echo "Max RSS (KB):                                 ", mxnMaxRss
    echo "Runtime RSS (KB):                             ", mxnRuntimeRSS
    echo "# of page faults:                             ", mxnPageFaults
    echo "Perf (GMEMOPs/s ~ GigaMemory Operations/s)    ", round(nxmPerf, 3)

template runBench(transposeName: typed, reorderCompute: bool): untyped =
  if not reorderCompute:
    memUsage(mxnMaxRss, mxnRuntimeRss, mxnPageFaults):
      let start = wtime_msec()
      for _ in 0 ..< nrounds:
        transposeName(M, N, bufIn, bufOut)
      let stop = wtime_msec()
      mxnTime = stop - start

    memUsage(nxmMaxRss, nxmRuntimeRss, nxmPageFaults):
      let start = wtime_msec()
      for _ in 0 ..< nrounds:
        transposeName(N, M, bufIn, bufOut)
      let stop = wtime_msec()
      nxmTime = stop - start

    report(M, N, nthreads, nrounds, reorderCompute,
        transposeStrat, reqOps, reqBytes,
        mxnTime, mxnMaxRSS, mxnRuntimeRss, mxnPageFaults,
        nxmTime, nxmMaxRSS, nxmRuntimeRss, nxmPageFaults
      )
  else:
    memUsage(nxmMaxRss, nxmRuntimeRss, nxmPageFaults):
      let start = wtime_msec()
      for _ in 0 ..< nrounds:
        transposeName(N, M, bufIn, bufOut)
      let stop = wtime_msec()
      nxmTime = stop - start

    memUsage(mxnMaxRss, mxnRuntimeRss, mxnPageFaults):
      let start = wtime_msec()
      for _ in 0 ..< nrounds:
        transposeName(M, N, bufIn, bufOut)
      let stop = wtime_msec()
      mxnTime = stop - start

    report(M, N, nthreads, nrounds, reorderCompute,
        transposeStrat, reqOps, reqBytes,
        mxnTime, mxnMaxRSS, mxnRuntimeRss, mxnPageFaults,
        nxmTime, nxmMaxRSS, nxmRuntimeRss, nxmPageFaults
      )

# Interface
# ---------------------------------------------------

proc main(M = 400, N = 4000, nrounds = 1000, transposeStrat = TiledCollapsed, reorderCompute=false) =
  echo "Inverting the transpose order may favor one transposition heavily for non-tiled strategies"

  let nthreads = if transposeStrat == Sequential: 1'i32
                 else: omp_get_num_threads()

  let (reqOps, reqBytes, bufSize) = computeMeta(M, N)

  let bufOut = wv_alloc(float32, bufSize)
  let bufIn = wv_alloc(float32, bufSize)

  bufIn.initialize(bufSize)

  var mxnTime, nxmTime: float64

  case transposeStrat
  of Sequential: runBench(sequentialTranspose, reorderCompute)
  of Naive: runBench(ompNaiveTranspose, reorderCompute)
  of Collapsed: runBench(ompCollapsedTranspose, reorderCompute)
  of TiledCollapsed: runBench(omp2DTiledCollapsedTranspose, reorderCompute)

  wv_free(bufOut)
  wv_free(bufIn)

dispatch(main)
