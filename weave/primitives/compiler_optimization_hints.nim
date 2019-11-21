type
  PrefetchRW* {.size: cint.sizeof.} = enum
    Read = 0
    Write = 1
  PrefetchLocality* {.size: cint.sizeof.} = enum
    NoTemporalLocality = 0 # Data can be discarded from CPU cache after access
    LowTemporalLocality = 1
    ModerateTemporalLocality = 2
    HighTemporalLocality = 3 # Data should be left in all levels of cache possible
    # Translation
    # 0 - use no cache eviction level
    # 1 - L1 cache eviction level
    # 2 - L2 cache eviction level
    # 3 - L1 and L2 cache eviction level

const withBuiltins = defined(gcc) or defined(clang) or defined(icc)

when withBuiltins:
  proc builtin_prefetch(data: pointer, rw: PrefetchRW, locality: PrefetchLocality) {.importc: "__builtin_prefetch", noDecl.}

template prefetch*(
            data: pointer,
            rw: static PrefetchRW = Read,
            locality: static PrefetchLocality = HighTemporalLocality) =
  ## Prefetch examples:
  ##   - https://scripts.mit.edu/~birge/blog/accelerating-code-using-gccs-prefetch-extension/
  ##   - https://stackoverflow.com/questions/7327994/prefetching-examples
  ##   - https://lemire.me/blog/2018/04/30/is-software-prefetching-__builtin_prefetch-useful-for-performance/
  ##   - https://www.naftaliharris.com/blog/2x-speedup-with-one-line-of-code/
  when withBuiltins:
    builtin_prefetch(data, rw, locality)
  else:
    discard
