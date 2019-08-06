import std/bitops

# TODO: consider bloom filters?
#       or Nim builtin sets?
#       The slow part would be
#       victim selection when only a few remain.

template bit*(n: SomeInteger): uint32 =
  1'u32 shl n

template bit_mask_32*(n: SomeInteger): uint32 =
  # Saturated bitfield mask
  if n >= 32: high(uint32)
  else: bit(n) - 1

template zero_rightmost_one_bit*(n: uint32): uint32 =
  bitand(n, (n - 1))

func count_one_bits*(n: uint32): int32 =
  countSetBits(n).int32

template isolate_rightmost_one_bit(n: uint32): uint32 =
  ## Returns a bitset with only the rightmost bit from
  ## the input set.
  bitand(n, bitnot(n-1))

func rightmost_one_bit_pos*(n: uint32): int32 =
  # TODO: use fastLog2

  # assert bf.buffer != 0
  # n.isolate_rightmost_one_bit.fastLog2

  result = -1
  var i = isolate_rightmost_one_bit(n)
  while i != 0:
    inc result
    i = i shr 1
