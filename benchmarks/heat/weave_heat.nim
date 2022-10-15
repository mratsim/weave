# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# From fibril
#
# Original license
#
# /*
#  * Heat diffusion (Jacobi-type iteration)
#  *
#  * Volker Strumpen, Boston                                 August 1996
#  *
#  * Copyright (c) 1996 Massachusetts Institute of Technology
#  *
#  * This program is free software; you can redistribute it and/or modify
#  * it under the terms of the GNU General Public License as published by
#  * the Free Software Foundation; either version 2 of the License, or
#  * (at your option) any later version.
#  *
#  * This program is distributed in the hope that it will be useful,
#  * but WITHOUT ANY WARRANTY; without even the implied warranty of
#  * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  * GNU General Public License for more details.
#  *
#  * You should have received a copy of the GNU General Public License
#  * along with this program; if not, write to the Free Software
#  * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#  */

import
  # Stdlib
  strformat, os, strutils, math, system/ansi_c,
  cpuinfo,
  # Weave
  ../../weave
when not defined(windows):
  # bench
  import ../wtime, ../resources

# Helpers
# -------------------------------------------------------

# We need a thin wrapper around raw pointers for matrices,
# we can't pass "var seq[seq[float64]]" to other threads
# nor "var" for that matter
type
  Matrix[T] = object
    buffer: ptr UncheckedArray[T]
    m, n: int

  Row[T] = object
    buffer: ptr UncheckedArray[T]
    len: int

func newMatrix[T](m, n: int): Matrix[T] {.inline.} =
  result.buffer = cast[ptr UncheckedArray[T]](c_malloc(csize_t m*n*sizeof(T)))
  result.m = m
  result.n = n

template `[]`[T](mat: Matrix[T], row, col: Natural): T =
  # row-major storage
  assert row < mat.m
  assert col < mat.n
  mat.buffer[row * mat.n + col]

template `[]=`[T](mat: Matrix[T], row, col: Natural, value: T) =
  assert row < mat.m
  assert col < mat.n
  mat.buffer[row * mat.n + col] = value

func getRow[T](mat: Matrix[T], rowIdx: Natural): Row[T] {.inline.} =
  # row-major storage, there are n columns in between each rows
  assert rowIdx < mat.m
  result.buffer = cast[ptr UncheckedArray[T]](mat.buffer[rowIdx * mat.n].addr)
  result.len = mat.m

template `[]`[T](row: Row[T], idx: Natural): T =
  assert idx < row.len
  row.buffer[idx]

template `[]=`[T](row: Row[T], idx: Natural, value: T) =
  assert idx < row.len
  row.buffer[idx] = value

func delete[T](mat: sink Matrix[T]) =
  c_free(mat.buffer)

# And an auto converter for int32 -> float64 so we don't have to convert
# all i, j indices manually

converter i32toF64(x: int32): float64 {.inline.} =
  float64(x)

# -------------------------------------------------------

template f(x, y: SomeFloat): SomeFloat =
  sin(x) * sin(y)

template randa[T: SomeFloat](x, t: T): T =
  T(0.0)

proc randb(x, t: SomeFloat): SomeFloat {.inline.} =
  # proc instead of template to avoid Nim constant folding bug:
  # https://github.com/nim-lang/Nim/issues/12783
  exp(-2 * t) * sin(x)

template randc[T: SomeFloat](y, t: T): T =
  T(0.0)

proc randd(y, t: SomeFloat): SomeFloat {.inline.} =
  # proc instead of template to avoid Nim constant folding bug:
  # https://github.com/nim-lang/Nim/issues/12783
  exp(-2 * t) * sin(y)

template solu(x, y, t: SomeFloat): SomeFloat =
  exp(-2 * t) * sin(x) * sin(y)

const n = 4096'i32

var
  nx, ny, nt: int32
  xu, xo, yu, yo, tu, to: float64

  dx, dy, dt: float64
  dtdxsq, dtdysq: float64

  odd: Matrix[float64]
  even: Matrix[float64]

proc heat(m: Matrix[float64], il, iu: int32): bool {.discardable, gcsafe.}=
  # TODO to allow awaiting `heat` we return a dummy bool
  # The parallel spawns are updating the same matrix cells otherwise
  if iu - il > 1:
    let im = (il + iu) div 2

    let h = spawn heat(m, il, im)
    heat(m, im, iu)
    discard sync(h)
    return true
  # ------------------------

  let i = il
  let row = m.getRow(i)

  if i == 0:
    for j in 0 ..< ny:
      row[j] = randc(yu + j*dy, 0)
  elif i == nx - 1:
    for j in 0 ..< ny:
      row[j] = randd(yu + j*dy, 0)
  else:
    row[0] = randa(xu + i*dx, 0)
    for j in 1 ..< ny - 1:
      row[j] = f(xu + i*dx, yu + j*dy)
    row[ny - 1] = randb(xu + i*dx, 0)

proc diffuse(output: Matrix[float64], input: Matrix[float64], il, iu: int32, t: float64): bool {.discardable, gcsafe.} =
  # TODO to allow awaiting `diffuse` we return a dummy bool
  # The parallel spawns are updating the same matrix cells otherwise
  if iu - il > 1:
    let im = (il + iu) div 2

    let d = spawn diffuse(output, input, il, im, t)
    diffuse(output, input, im, iu, t)
    discard sync(d)
    return true
  # ------------------------

  let i = il
  let row = output.getRow(i)

  if i == 0:
    for j in 0 ..< ny:
      row[j] = randc(yu + j*dy, t)
  elif i == nx - 1:
    for j in 0 ..< ny:
      row[j] = randd(yu + j*dy, t)
  else:
    row[0] = randa(xu + i*dx, t)
    for j in 1 ..< ny - 1:
      row[j] = input[i, j] + # The use of nested sequences here is a bad idea ...
               dtdysq * (input[i, j+1] - 2 * input[i, j] + input[i, j-1]) +
               dtdxsq * (input[i+1, j] - 2 * input[i, j] + input[i-1, j])
    row[ny - 1] = randb(xu + i*dx, t)

proc initTest() =
  nx = n
  ny = 1024
  nt = 100
  xu = 0.0
  xo = 1.570796326794896558
  yu = 0.0
  yo = 1.570796326794896558
  tu = 0.0
  to = 0.0000001

  dx = (xo - xu) / float64(nx - 1)
  dy = (yo - yu) / float64(ny - 1)
  dt = (to - tu) / float64(nt)

  dtdxsq = dt / (dx * dx)
  dtdysq = dt / (dy * dy)

  even = newMatrix[float64](nx, ny)
  odd = newMatrix[float64](nx, ny)

proc prep() =
  heat(even, 0, nx)

proc test() =
  var t = tu

  for _ in countup(1, nt.int, 2):
    # nt included
    t += dt
    diffuse(odd, even, 0, nx, t)
    t += dt
    diffuse(even, odd, 0, nx, t)

  if nt mod 2 != 0:
    t += dt
    diffuse(odd, even, 0, nx, t)

proc verify() =
  var
    mat: Matrix[float64]
    mae: float64
    mre: float64
    me:  float64

  mat = if nt mod 2 != 0: odd else: even

  for a in 0 ..< nx:
    for b in 0 ..< ny:
      var tmp = abs(mat[a, b] - solu(xu + a*dx, yu + b*dy, to))
      if tmp > 1e-3:
        echo "nx: ", nx, " - ny: ", ny
        echo "mat[", a, ", ", b, "] = ", mat[a, b], ", expected sol = ", solu(xu + a*dx, yu + b*dy, to)
        quit 1

      me += tmp
      if tmp > mae: mae = tmp
      if mat[a, b] != 0.0: tmp /= mat[a, b]
      if tmp > mre: mre = tmp

  me /= nx * ny

  if mae > 1e-12:
    echo &"Local maximal absolute error {mae:1.3e}"
    quit 1
  if mre > 1e-12:
    echo &"Local maximal relative error {mre:1.3e}"
    quit 1
  if me > 1e-12:
    echo &"Global mean absolute error {me:1.3e}"
    quit 1

  echo "Verification successful"

proc main() =
  var nthreads: int
  if existsEnv"WEAVE_NUM_THREADS":
    nthreads = getEnv"WEAVE_NUM_THREADS".parseInt()
  else:
    nthreads = countProcessors()

  when not defined(windows):
    var ru: Rusage
    getrusage(RusageSelf, ru)
    var
      rss = ru.ru_maxrss
      flt = ru.ru_minflt

  initTest()

  # Fibril initializes before benching
  init(Weave)

  prep()
  when not defined(windows):
    let start = wtime_usec()
  test()
  when not defined(windows):
    let stop = wtime_usec()

    getrusage(RusageSelf, ru)
    rss = ru.ru_maxrss - rss
    flt = ru.ru_minflt - flt

  exit(Weave)

  verify()
  delete(even)
  delete(odd)

  const lazy = defined(WV_LazyFlowvar)
  const config = if lazy: " (lazy flowvars)"
                 else: " (eager flowvars)"

  echo "Scheduler:        Weave", config
  echo "Benchmark:        heat"
  echo "Threads:          ", nthreads
  when not defined(windows):
    echo "Time(us)          ", stop - start
    echo "Max RSS (KB):     ", ru.ru_maxrss
    echo "Runtime RSS (KB): ", rss
    echo "# of page faults: ", flt

  quit 0

main()
