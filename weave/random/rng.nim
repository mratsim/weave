# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import ../instrumentation/contracts

# Random Number Generator
# ----------------------------------------------------------------------------------

# The RNG will be used for victim selection
# Unfortunately xoroshiro128+ (Nim default) low bits fails linearity tests
# We need to use the high bits instead which Nim random doesn't allow us to do.
# We might aswell use xoshiro256++ which is almost as fast but doesn't fail
# Hamming Weight dependency test after 5 TB of data
# and has a period of 2^256-1 instead of 2^128.
# Compared to xoshiro256+ (and xoroshiro128+) the low bits
# don't have low linearity so we can directly take a modulo
# instead of shifting to only retain the high bits and then modulo.
#
# http://prng.di.unimi.it/
#
# We initialize the RNG with SplitMix64

type RngState* = object
  s0, s1, s2, s3: uint64

func splitMix64(state: var uint64): uint64 =
  state += 0x9e3779b97f4a7c15'u64
  result = state
  result = (result xor (result shr 30)) * 0xbf58476d1ce4e5b9'u64
  result = (result xor (result shr 27)) * 0xbf58476d1ce4e5b9'u64
  result = result xor (result shr 31)

func seed*(rng: var RngState, x: SomeInteger) =
  ## Seed the random number generator with a fixed seed
  var sm64 = uint64(x)
  rng.s0 = splitMix64(sm64)
  rng.s1 = splitMix64(sm64)
  rng.s2 = splitMix64(sm64)
  rng.s3 = splitMix64(sm64)

func rotl(x: uint64, k: static int): uint64 {.inline.} =
  return (x shl k) or (x shr (64 - k))

func next(rng: var RngState): uint64 =
  ## Compute a random uint64 from the input state
  ## using xoshiro256++ algorithm by Vigna et al
  ## State is updated.
  result = rotl(rng.s0 + rng.s3, 23) + rng.s0

  let t = rng.s1 shl 17
  rng.s2 = rng.s2 xor rng.s0
  rng.s3 = rng.s3 xor rng.s1
  rng.s1 = rng.s1 xor rng.s2
  rng.s0 = rng.s0 xor rng.s3

  rng.s2 = rng.s2 xor t

  rng.s3 = rotl(rng.s3, 45)

func uniform*(rng: var RngState, max: SomeInteger): int32 =
  ## Returns a random integer in the range 0 ..< max
  ## Unlike Nim ``random`` stdlib, max is excluded.
  preCondition: max > 0
  while true:
    let x = rng.next()
    if x <= high(uint64) - (high(uint64) mod uint64(max)):
      # We use rejection sampling to have a uniform distribution
      return int32(x mod uint64(max))
