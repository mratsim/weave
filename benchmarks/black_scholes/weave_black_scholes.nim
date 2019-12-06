# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Reference implementation from
# // Copyright (c) 2007 Intel Corp.
#
# // Black-Scholes
# // Analytical method for calculating European Options
# //
# //
# // Reference Source: Options, Futures, and Other Derivatives, 3rd Edition, Prentice
# // Hall, John C. Hull,
#
# File manipulation routines ported from C++-Taskflow

import
  # Stdlib
  strformat, os, strutils, math, system/ansi_c,
  cpuinfo, streams, strscans,
  # Third-party
  cligen,
  # Weave
  ../../weave,
  # bench
  ../wtime, ../resources

# Types
# --------------------------------

type
  OptionKind = enum
    Put
    Call

  OptionData[T: SomeFloat] = object
    spot: T     # Spot price
    strike: T   # Strike price
    riskfree: T # risk-free rate
    divrate: T  # dividend rate
    vol: T      # volatility
    expiry: T   # expiry to maturity or option expiration in years
                # (1 year = 1.0, 6 months = 0.5)
    kind: OptionKind
    divvals: T  # Dividend values (not used in this test)
    dgrefval: T # DerivaGem reference value

  Context[T: SomeFloat] = object
    data: ptr UncheckedArray[OptionData[T]]
    prices: ptr UncheckedArray[T]
    numOptions: int
    numRuns: int

    otype: ptr UncheckedArray[OptionKind]
    spot: ptr UncheckedArray[T]
    strike: ptr UncheckedArray[T]
    riskFreeRate: ptr UncheckedArray[T]
    volatility: ptr UncheckedArray[T]
    expiry: ptr UncheckedArray[T]
    numErrors: int

# Helpers
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

proc initialize[T](ctx: var Context[T], numOptions: int) =
  ctx.numOptions = numOptions

  ctx.data = wv_alloc(OptionData[T], numOptions)
  ctx.prices = wv_alloc(T, numOptions)
  ctx.otype = wv_alloc(OptionKind, numOptions)
  ctx.spot = wv_alloc(T, numOptions)
  ctx.strike = wv_alloc(T, numOptions)
  ctx.riskFreeRate = wv_alloc(T, numOptions)
  ctx.volatility = wv_alloc(T, numOptions)
  ctx.expiry = wv_alloc(T, numOptions)

proc delete[T](ctx: sink Context[T]) =

  wv_free ctx.data
  wv_free ctx.prices
  wv_free ctx.otype
  wv_free ctx.spot
  wv_free ctx.strike
  wv_free ctx.riskFreeRate
  wv_free ctx.volatility
  wv_free ctx.expiry

# Cumulative Normal Distribution Function
# ---------------------------------------------------
# See Hull, Section 11.8, P.243-244

const InvSqrt2xPI = 0.39894228040143270286

func cumulNormalDist[T: SomeFloat](inputX: T): T =

  # Check for negative value of inputX
  var isNegative = false
  var inputX = inputX
  if inputX < 0.T:
    inputX = -inputX
    isNegative = true

  let xInput = inputX

  # Compute NPrimeX term common to both four & six decimal accuracy calcs
  let expValues = exp(-0.5.T * inputX * inputX)
  let xNPrimeofX = expValues * InvSqrt2xPI

  let
    xK2 = 1.0 / (1.0 + 0.2316419*xInput)
    xK2_2 = xK2 * xK2
    xK2_3 = xK2_2 * xK2
    xK2_4 = xK2_3 * xK2
    xK2_5 = xK2_4 * xK2

  var
    xLocal_1 = xK2 * 0.319381530
    xLocal_2 = xK2_2 * -0.356563782
    xLocal_3 = xK2_3 * 1.781477937
  xLocal_2 += xLocal_3
  xLocal_3 = xK2_4 * -1.821255978
  xLocal_2 += xLocal_3
  xLocal_3 = xK2_5 * 1.330274429
  xLocal_2 += xLocal_3

  xLocal_1 += xLocal_2
  result = 1.T - xLocal_1 * xNPrimeofX

  if isNegative:
    result = 1.T - result

# Black & Scholes
# ---------------------------------------------------

func blackScholesEqEuroNoDiv[T](
    spot, strike, riskFreeRate, volatility, expiry: T,
    otype: OptionKind,
    timet: float32
  ): T =

  var xD1 = riskFreeRate + 0.5.T * volatility * volatility
  xD1 *= expiry
  xD1 += ln(spot / strike)

  var xDen = volatility * sqrt(expiry)
  xD1 /= xDen

  let xD2 = xD1 - xDen

  let nofXd1 = cumulNormalDist(xD1)
  let nofXd2 = cumulNormalDist(xD2)

  let futureValueX = strike * exp(-riskFreeRate*expiry)
  if otype == Call:
    result = spot * nofXd1 - futureValueX * nofXd2
  else:
    let negNofxd1 = 1.T - nofXd1
    let negNofxd2 = 1.T - nofXd2
    result = futureValueX * negNofxd2 - spot * negNofXd1

func checkErrors[T](ctx: var Context[T], i: int, price: T) =
  let priceDelta = ctx.data[i].dgrefval - price
  if abs(priceDelta) >= 1e-4:
    c_printf("Error on %d. Computed=%.5f, Ref=%.5f, Delta=%.5f\n",
      i.int, price, ctx.data[i].dgrefval, priceDelta
    )
    ctx.numErrors += 1

func blackScholesSequential(ctx: var Context) =

  for j in 0 ..< ctx.numRuns:
    for i in 0 ..< ctx.numOptions:
      let price = blackScholesEqEuroNoDiv(
        ctx.spot[i], ctx.strike[i],
        ctx.riskFreeRate[i], ctx.volatility[i],
        ctx.expiry[i], ctx.otype[i], 0
      )
      ctx.prices[i] = price

      when defined(check):
        checkErrors(ctx, i, price)

proc blackScholesWeave(ctx: ptr Context) =

  for j in 0 ..< ctx.numRuns:
    parallelFor i in 0 ..< ctx.numOptions:
      captures: {ctx}
      let price = blackScholesEqEuroNoDiv(
        ctx.spot[i], ctx.strike[i],
        ctx.riskFreeRate[i], ctx.volatility[i],
        ctx.expiry[i], ctx.otype[i], 0
      )
      ctx.prices[i] = price

      when defined(check):
        checkErrors(ctx[], i, price)

proc dump[T](ctx: Context[T], file: string) =

  let stream = openFileStream(file, fmWrite)
  defer: stream.close()

  stream.write($ctx.numOptions)
  stream.write("\n")

  for i in 0 ..< ctx.numOptions:
    stream.write($ctx.prices[i])
    stream.write("\n")

proc parseOptions[T](ctx: var Context[T], optFile: string) =

  let stream = openFileStream(optFile, fmRead)
  defer: stream.close()

  var line: string
  discard stream.readLine(line)

  # Allocate the buffers
  # Note sure why the original bench uses a struct of arrays
  let numOptions = line.parseInt()
  ctx.initialize(numOptions)
  echo "Reading ", numOptions, " options"

  # For parsing Nim uses float64 by default
  var
    spot, strike, riskfree, divrate, vol, expiry: float64
    optKind: string
    divvals, dgrefval: float64

  for i in 0 ..< ctx.numOptions:
    discard stream.readLine(line)
    let isLineParsed = scanf(line, "$f $f $f $f $f $f $w $f $f",
        spot, strike, riskFree,
        divrate, vol, expiry,
        optKind, divvals, dgrefval
      )
    doAssert isLineParsed

    ctx.data[i].spot = spot.T
    ctx.data[i].strike = strike.T
    ctx.data[i].riskfree = riskfree.T
    ctx.data[i].divrate = divrate.T
    ctx.data[i].vol = vol.T
    ctx.data[i].expiry = expiry.T
    ctx.data[i].divvals = divvals.T
    ctx.data[i].dgrefval = dgrefval.T

    if optKind == "C":
      ctx.data[i].kind = Call
    elif optKind == "P":
      ctx.data[i].kind = Put
    else:
      raise newException(ValueError, "Invalid option kind: \"" & optKind & '"')

    ctx.otype[i] = ctx.data[i].kind
    ctx.spot[i] = ctx.data[i].spot
    ctx.strike[i] = ctx.data[i].strike
    ctx.riskFreeRate[i] = ctx.data[i].riskfree
    ctx.volatility[i] = ctx.data[i].vol
    ctx.expiry[i] = ctx.data[i].expiry

proc main(numRounds = 2000, input: string, output = "") =

  var ctx: Context[float32]
  ctx.numRuns = numRounds
  ctx.parseOptions(input)

  var nthreads: int
  if existsEnv"WEAVE_NUM_THREADS":
    nthreads = getEnv"WEAVE_NUM_THREADS".parseInt()
  else:
    nthreads = countProcessors()

  var ru: Rusage
  getrusage(RusageSelf, ru)
  var
    rss = ru.ru_maxrss
    flt = ru.ru_minflt

  let start = wtime_msec()
  init(Weave)
  blackScholesWeave(ctx.addr)
  exit(Weave)
  let stop = wtime_msec()

  getrusage(RusageSelf, ru)
  rss = ru.ru_maxrss - rss
  flt = ru.ru_minflt - flt


  const lazy = defined(WV_LazyFlowvar)
  const config = if lazy: " (lazy flowvars)"
                 else: " (eager flowvars)"

  echo "--------------------------------------------------------------------------"
  echo "Scheduler:                                    Weave", config
  echo "Benchmark:                                    Black & Scholes Option Pricing"
  echo "Threads:                                      ", nthreads
  echo "Time(ms)                                      ", round(stop - start, 3)
  echo "Max RSS (KB):                                 ", ru.ru_maxrss
  echo "Runtime RSS (KB):                             ", rss
  echo "# of page faults:                             ", flt
  echo "--------------------------------------------------------------------------"
  echo "# of rounds:                                  ", numRounds
  echo "# of options:                                 ", ctx.numOptions

  if output != "":
    echo "\nDumping prices to \"", output, '"'
    dump(ctx, output)

  delete(ctx)

  quit 0

dispatch(main)
