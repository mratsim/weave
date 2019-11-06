import std/bitops

type
  VictimsBitset = object
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
# Proc indirection is costly, and {.inine.} is not always guaranteed

