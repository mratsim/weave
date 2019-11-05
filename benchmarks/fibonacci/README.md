# Fibonacci benchmarks

⚠️ Disclaimer:
   Please don't use parallel fibonacci in production!
   Use the fast doubling method with memoization instead.

Fibonacci benchmark has 3 draws:

1. It's very simple to implement
2. It's unbalanced and efficiency requires distributions to avoid idle cores.
3. It's a very effective scheduler overhead benchmark, because the basic task is very  trivial and the task spawning grows at 2^n scale.


Want to know the difference between low and high overhead?

Run the following C code (taken from [Oracle OpenMP example](https://docs.oracle.com/cd/E19205-01/820-7883/girtd/index.html))

```C
#include <stdio.h>
#include <omp.h>
int fib(int n)
{
  int i, j;
  if (n<2)
    return n;
  else
    {
       #pragma omp task shared(i) firstprivate(n)
       {
         i=fib(n-1);
       }

       j=fib(n-2);
       #pragma omp taskwait
       return i+j;
    }
}

int main()
{
  int n = 40;

  #pragma omp parallel shared(n)
  {
    #pragma omp single
    printf ("fib(%d) = %d\n", n, fib(n));
  }
}
```

First compile with Clang and run it
```
clang -O3 -fopenmp benchmarks/fibonacci/omp_fib.c
time a.out
```
It should be fairly quick


Then compile with GCC and run it
```
gcc -O3 -fopenmp benchmarks/fibonacci/omp_fib.c
time a.out
```

Notice how some cores get idle as time goes on?
Don't forget to kill the benchmark, you'll be there all day.

What's happening?

GCC's OpenMP implementation uses a single queue for all tasks.
That queue gets constantly hammered by all threads and becomes a contention point.
Furthermore, it seems like there is no load balancing or that due to the contention/lock
threads are descheduled.

However Clang implementation uses a work-stealing scheduler with one deque per thread.
The only contention happens when a thread run out of work and has to look for more work,
in the deque of other threads. And which thread to check is chosen at random so
the potential contention is distributed among all threads instead of a single structure.
