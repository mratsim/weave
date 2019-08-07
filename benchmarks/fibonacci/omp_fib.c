#include <stdio.h>
#include <omp.h>

// Compile with "gcc -O3 -fopenmp benchmarks/fibonacci/omp_fib.c"
// and "clang -O3 -fopenmp benchmarks/fibonacci/omp_fib.c"
// GCC will be very slow due to their OpenMP implementation
// using a global task queue which will be a huge contention point.
// Clang uses work-stealing with each thread owning a private deque.

long long fib(long long n)
{
  long long i, j;
  if (n<2)    // Note: be sure to compare n<2 -> return n
    return n; //       instead of n<=2 -> return 1
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

int main(int argc, char *argv[])
{

	if (argc != 2) {
    printf("Usage: fib <n-th fibonacci number requested>\n");
		exit(0);
	}

  long long n = atoi(argv[1]);

  #pragma omp parallel shared(n)
  {
    #pragma omp single
    printf ("fib(%lld) = %lld\n", n, fib(n));
  }
}
