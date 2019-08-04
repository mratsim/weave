type
  Bitfield*[T: SomeUnsignedInt] = object
    ## Implementation of a bitfield
    ## Bit-endianness is little endian
    ## i.e. bit 0 refers to the least significant bit
    buffer: T

template msb_pos(T: typedesc): int =
  ## Position of the most significant bit
  sizeof(T) * 8 - 1

func initBitfieldSetUpTo*[typ: SomeUnsignedInt](
        T: typedesc[typ],
        position: range[0 .. msb_pos(T)]
      ): BitField[T] {.inline.} =
  ## Init a bitfield with all bits set to 1
  ## up to `position` (inclusive)
  result.buffer = (1.T shl position) - 1

when isMainModule:
  echo initBitfieldSetUpTo(uint32, 10)
