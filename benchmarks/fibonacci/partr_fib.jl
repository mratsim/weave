# Requires Julia 1.3 (in beta)
# Run with JULIA_NUM_THREADS=36 benchmarks/partr_fib.jl

import Base.Threads.@spawn

function fib(n::Int)
    if n < 2
        return n
    end
    x = @spawn fib(n - 1)
    y = fib(n - 2)
    return fetch(x) + y
end

function main()
  n = parse(Int, ARGS[1])
  println(fib(n))
end

main()
