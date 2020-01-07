# Laser
# Copyright (c) 2018-Present Mamy André-Ratsimbazafy
# Distributed under the Apache v2 License (license terms are at http://www.apache.org/licenses/LICENSE-2.0).
# This file may not be copied, modified, or distributed except according to those terms.

import std/[sequtils, times, monotimes, stats, strformat, random]

type
  MatrixShape* = tuple[M, N: int]
  Matrix*[T] = seq[T]

func gemm_out_shape*(
      a: MatrixShape,
      b: MatrixShape,
    ): MatrixShape =

  doAssert a.N == b.M

  result.M = a.M
  result.N = b.N

func gemm_required_ops*(
      a: MatrixShape,
      b: MatrixShape
    ): int =
  doAssert a.N == b.M
  result = a.M * a.N * b.N * 2 # (1 add, 1 mul)

func gemm_required_data*(
      a: MatrixShape,
      b: MatrixShape
    ): int =
  doAssert a.N == b.M
  result = a.M * a.N + b.M * b.N

iterator flatIter*[T](s: openarray[T]): auto {.noSideEffect.}=
  for item in s:
    when item is array|seq:
      for subitem in flatIter(item):
        yield subitem
    else:
      yield item

func toMatrix*[T](oa: openarray[T]): auto =
  ## Convert to a flattened tensor/image
  toSeq(flatiter(oa))

proc toString*(mat: Matrix, shape: MatrixShape): string =
  for i in 0 ..< shape.M:
    for j in 0 ..< shape.N:
      let idx = j + shape.N * i
      result.add $mat[idx] & '\t'
    result.add '\n'

proc warmup*() =
  # Warmup - make sure cpu is on max perf
  let start = getMonoTime()
  var foo = 123
  for i in 0 ..< 500_000_000:
    foo += i*i mod 456
    foo = foo mod 789

  let stop = getMonoTime()
  echo &"Warmup: {inMilliseconds(stop - start)} ms, result {foo} (displayed to avoid compiler optimizing warmup away)"

export stats # Workaround strformat symbol binding issue
template printStats(name: string, result: openarray) {.dirty.} =
  bind `&`
  echo "\n" & name
  echo &"Collected {stats.n} samples in {globalElapsed} ms"
  echo &"Average time: {mean(stats):>4.3f} ms"
  echo &"Stddev  time: {standardDeviationS(stats):>4.3f} ms"
  echo &"Min     time: {stats.min:>4.3f} ms"
  echo &"Max     time: {stats.max:>4.3f} ms"
  # 1 millisecond -> 1e-3 seconds => GFLOPs = 1e-9 FLOP / s = 1e-9 FLOP / 1e-3 ms = 1e-6 FLOP / ms
  echo &"Perf:         {req_ops.float / stats.mean * 1e-6:>4.3f} GFLOP/s"

template bench*(name: string, req_ops: int, initialisation, body: untyped) {.dirty.}=
  bind printStats, RunningStat, getMonoTime, push, inMilliseconds, `-`
  block: # Actual bench
    var stats: RunningStat
    let global_start = getMonoTime()
    for _ in 0 ..< nb_samples:
      initialisation
      let start = getMonoTime()
      body
      let stop = getMonoTime()
      push(stats, int inMilliseconds(stop - start))
    let global_stop = getMonoTime()
    let globalElapsed = inMilliseconds(global_stop - global_start)
    printStats(name, result)

proc relative_error*[T: SomeFloat](y, y_true: T): T {.inline.} =
  ## Relative error, |y_true - y|/max(|y_true|, |y|)
  ## Normally the relative error is defined as |y_true - y| / |y_true|,
  ## but here max is used to make it symmetric and to prevent dividing by zero,
  ## guaranteed to return zero in the case when both values are zero.
  let denom = max(abs(y_true), abs(y))
  if denom == 0.T:
    return 0.T
  result = abs(y_true - y) / denom

proc absolute_error*[T: SomeFloat](y, y_true: T): T {.inline.} =
  ## Absolute error for a single value, |y_true - y|
  result = abs(y_true - y)

proc mean_relative_error*[T: SomeFloat](y, y_true: seq[T]): T {.inline.} =
  doAssert y.len == y_true.len

  result = 0.T
  for i in 0 ..< y.len:
    result += relative_error(y[i], y_true[i])
  result = result / y.len.T

proc mean_absolute_error*[T: SomeFloat](y, y_true: seq[T]): T {.inline.} =
  doAssert y.len == y_true.len

  result = 0.T
  for i in 0 ..< y.len:
    result += absolute_error(y[i], y_true[i])
  result = result / y.len.T
