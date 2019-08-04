import std/bitops

type
  Bitfield*[T: SomeUnsignedInt] = object
    ## Implementation of a bitfield
    ## Bit-endianness is little endian
    ## i.e. bit 0 refers to the least significant bit
    buffer*: T

template msb_pos(T: typedesc): int =
  ## Position of the most significant bit
  # Note: that causes issue with sizeof
  sizeof(T) * 8 - 1

func initBitfieldSetUpTo*[typ: SomeUnsignedInt](
        T: typedesc[typ],
        position: range[0 .. msb_pos(T)]
      ): BitField[T] {.inline.} =
  ## Init a bitfield with all bits set to 1
  ## up to `position` (inclusive)
  result.buffer = (1.T shl position) - 1

func isEmpty*(bf: Bitfield): bool {.inline.} =
  bf.buffer == 0

func isSet*[T](bf: Bitfield[T], bit: range[0 .. msb_pos(T)]): bool {.inline.} =
  bool((bf.buffer shr bit) and 1)

func setBit*[T](bf: var Bitfield[T], bit: range[0 .. msb_pos(T)]) {.inline.}=
  bf.buffer.setBit(bit)

func clearBit*[T](bf: var Bitfield[T], bit: T) {.inline.}=
  bf.buffer.clearBit(bit)

func flipBit*[T](bf: var Bitfield[T], bit: range[0 .. msb_pos(T)]) {.inline.}=
  bf.buffer.flipBit(bit)

func `-`[T: SomeUnsignedInt](n: T): T {.inline.}=
  ## Unary negate. Assumes 2-complement arch
  # assert -int(n) == not(int(n)) + 1, "Only 2-complement architectures are supported"
  not(n) + 1

func bitfieldWithOnlyLSBset(bf: Bitfield): Bitfield {.inline.}=
  ## Returns a new bitfield with only
  ## the least significant bit set of the input set
  result.buffer = bf.buffer and -bf.buffer

func getLSBset*[T](bf: Bitfield[T]): range[0.T .. msb_pos(T)] {.inline.}=
  ## Returns the least significant bit set
  ## Result is undefined if no bits are set at all
  assert bf.buffer != 0
  bf.bitfieldWithOnlyLSBset().buffer.fastLog2()

func lsbSetCleared*[T](bf: Bitfield[T]): Bitfield[T] {.inline.} =
  ## Returns a new bitfield with the least significant bit set cleared.
  result.buffer = bf.buffer and (bf.buffer - 1)

func countSetBits*(bf: Bitfield): int32 {.inline.} =
  ## Returns the number of set bits
  ## i.e. popcount or Hamming Weight
  bf.buffer.countSetBits().int32
