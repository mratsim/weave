-- Requires monad-par
-- Install via "stack install monad-par"
-- Compile with "ghc -dynamic -threaded -o build/monadpar_fib benchmarks/fibonacci/monadpar_fib.hs"
-- Assuming 36 cores
-- Run with "build/monadpar_fib 40 +RTS -N36"
--
-- From https://github.com/simonmar/monad-par/blob/master/examples/src/parfib/parfib-monad.hs
-- Paper: https://cs.indiana.edu/~rrnewton/papers/haskell2011_monad-par.pdf

{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -O2 #-}
import Data.Int
import System.Environment
import GHC.Conc
import Control.Monad.Par

fib :: Int64 -> Par Int64
fib n | n < 2 = return n
fib n = do
    xf <- spawn_$ fib (n-1)
    y  <-         fib (n-2)
    x  <- get xf
    return (x+y)

main :: IO ()
main = do
    args <- getArgs
    let (n) = case args of
            [n]   -> (read n)

    print$ runPar$ fib n
