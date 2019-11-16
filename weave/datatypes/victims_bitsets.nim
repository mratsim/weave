import std/bitops

type
  VictimsBitset* = object
    ## Packed representation of potential victims
    ## as a bitset
    # TODO: support more than 32 cores
    # TODO: consider bloom filters / cuckoo filters?
    #       or Nim builtin sets?
    #       The slow part would be victim selection when only a few remain.
    #
    #       alternatively have a way to deal with Hyperthreading and NUMA
    #       as so far the max number of physical CPUs cores per socket is 32 / 64 threads
    #       with Ryzen 3960X and Epyc 7551P
    data: uint32

# We really want to enforce inlining so we use templates everywhere
# Proc indirection is costly, and {.inline.} is not always guaranteed

# We don't use WorkerID to avoid recursive imports

template bit(n: SomeInteger): uint32 =
  1'u32 shl n

func init*(v: var VictimsBitset, numVictims: SomeInteger) {.inline.} =
  let mask = if numVictims >= 32: high(uint32)
             else: bit(numVictims) - 1
  v.data = high(uint32) and mask

template isEmpty*(v: VictimsBitset): bool =
  v.data == 0

func clear*(v: var VictimsBitset, workerID: int32) {.inline.} =
  # v.data.clearBit(workerID) - TODO: bitset doesn't support > 32 CPU
  v.data = v.data and not bit(workerID)

func contains*(v: VictimsBitset, workerID: int32): bool {.inline.} =
  # TODO: Nim testBit could use a comparison "!= 0"
  #       instead of "== mask" to save on code size for bit-heavy libraries
  # v.data.testBit(workerID) - TODO: bitset doesn't support > 32 CPU
  bool((v.data shr workerID) and 1)

template len*(v: VictimsBitset): int32 =
  int32 countSetBits(v.data)

func shift1*(v: var VictimsBitset) {.inline.} =
  v.data = v.data shr 1

func zeroRightmostOneBit*(v: VictimsBitset): VictimsBitset {.inline.} =
  result.data = bitand(v.data, (v.data - 1))

template isolateRightmostOneBit(v: VictimsBitset): int32 =
  ## Returns a bitset with only the rightmost bit from
  ## the input set.
  int32 bitand(v.data, bitnot(v.data-1))

func rightmostOneBitPos*(v: VictimsBitset): int32 =
  # TODO: use fastLog2

  result = -1
  var i = isolateRightmostOneBit(v)
  while i != 0:
    inc result
    i = i shr 1
