# Log-Sum-Exp

Log-Sum-Exp computes `ln ∑i exp(xi)` by using the trick:

```
log ∑i exp(xi) = α + log ∑i exp(xi−α)
with α = max(xi) for xi in x
```

Log-Sum-Exp is a key algorithm behind the Softmax Cross-Entropy loss function,
which is used in almost all deep learning classification problems.

Furthermore this is a huge bottleneck in NLP and research in fast softmax
approximation is active.

We are interested in testing parallel reductions
so we do first a parallel max and then a parallel exponential sum.

However note that there exist a streaming version
at http://www.nowozin.net/sebastian/blog/streaming-log-sum-exp-computation.html
which is similar to Welford algorithm for streaming mean and variance in statistics.

Given that exponential is a very heavy operation all framework should see a linear speedup.
The main challenge is the framework syntax for complex reduction operation.

Note that `<math.h>` exponential can be significantly improved (10x)
by using vectorization techniques from Laser
https://github.com/numforge/laser/blob/d1e6ae6106564bfb350d4e566261df97dbb578b3/benchmarks/vector_math/bench_exp_avx2.nim#L373-L379
