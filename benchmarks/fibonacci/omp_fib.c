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

int main(int argc, char *argv[])
{

	if (argc != 2) {
    printf("Usage: fib <n-th fibonacci number requested>");
		exit(0);
	}

  int n = atoi(argv[1]);

  #pragma omp parallel shared(n)
  {
    #pragma omp single
    printf ("fib(%d) = %d\n", n, fib(n));
  }
}
