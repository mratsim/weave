// Adapted from Intel https://www.threadingbuildingblocks.org/tutorial-intel-tbb-task-based-programming

#include <stdio.h>
#include <tbb/task_group.h>

// tbb headers and libtbb must be in your include and library paths.
// Compile with "gcc -O3 -ltbb -lstdc++ benchmarks/fibonacci/tbb_fib.cpp"

using namespace tbb;

long long Fib(long long n) {
    if( n<2 ) {
        return n;
    } else {
        int x, y;
        task_group g;
        g.run([&]{x=Fib(n-1);}); // spawn a task
        y=Fib(n-2);
        g.wait();                // wait for both tasks to complete
        return x+y;
    }
}

int main(int argc, char *argv[])
{

  if (argc != 2) {
  printf("Usage: fib <n-th fibonacci number requested>\n");
      exit(0);
  }

  long long n = atoi(argv[1]);

  printf("fib(%lld) = %lld\n", n, Fib(n));
}
