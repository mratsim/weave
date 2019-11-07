import std/bitops

type
  VictimsBitset* = object
    ## Packed representation of potential victims
    ## as a bitset
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

template isEmpty*(v: VictimsBitset): bool =
  v.data == 0

template bit*(n: int32): uint32 =
  1'u32 shl n

func clear*(v: var VictimsBitset, workerID: int32) {.inline.} =
  v.data = v.data and not bit(workerID)

template len*(v: VictimsBitset): int32 =
  int32 v.data.countSetBits()

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

template isPotentialVictim*(v: VictimsBitset, workerID: int32): bool =
  ((v.data and bit(workerID)) != 0) and workerID != 0
