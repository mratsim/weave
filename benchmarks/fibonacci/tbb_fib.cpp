// Adapted from Intel https://software.intel.com/en-us/node/506102
// How to change so that it compute the second term in the current task?

#include <stdio.h>
#include <tbb/task.h>

// tbb headers and libtbb must be in your include and library paths.
// Compile with "gcc -O3 -ltbb -lstdc++ benchmarks/fibonacci/tbb_fib.cpp"

using namespace tbb;

class FibTask: public task {
public:
    const long long n;
    long long* const sum;
    FibTask( long long n_, long long* sum_ ) :
        n(n_), sum(sum_)
    {}
    task* execute() {      // Overrides virtual function task::execute
        if( n<2 ) {        // Note: be sure to compare n<2 -> return n
            *sum = n;      //       instead of n<=2 -> return 1
            return nullptr;
        }

        long long x, y;
        FibTask& a = *new( allocate_child() ) FibTask(n-1,&x);
        FibTask& b = *new( allocate_child() ) FibTask(n-2,&y);
        // Set ref_count to 'two children plus one for the wait".
        set_ref_count(3);
        // Start b running.
        spawn( b );
        // Start a running and wait for all children (a and b).
        spawn_and_wait_for_all(a);
        // Do the sum
        *sum = x+y;

        return nullptr;
    }
};

int main(int argc, char *argv[])
{

	if (argc != 2) {
    printf("Usage: fib <n-th fibonacci number requested>\n");
		exit(0);
	}

  long long n = atoi(argv[1]);
  long long result;

  auto root = new(task::allocate_root()) FibTask(n, &result);
  task::spawn_root_and_wait(*root);

  printf("fib(%lld) = %lld\n", n, result);
}
