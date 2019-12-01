#include <iostream>
#include <chrono>
#include <thread>

#include <cilk/cilk.h>
#include <cilk/cilk_api.h>

using namespace std;
using namespace std::chrono;

void fib(int n, unsigned long *sum)
{
	if (n < 2) {
		*sum = 1;
		return;
	}

	unsigned long x;
	cilk_spawn fib(n - 1, &x);

	unsigned long y;
	fib(n - 2, &y);

	cilk_sync;

	*sum = x + y;
}

void test(int n, unsigned long *sum)
{
	cilk_spawn fib(n, sum);
	cilk_sync;
}

int main(int argc, char *argv[])
{
	size_t n = 40;
	unsigned long answer;
	const char *nthreads = nullptr;

	if (argc >= 2)
		nthreads = argv[1];
	if (argc >= 3)
		n = atoi(argv[2]);
	if (nthreads == nullptr)
		nthreads = to_string(thread::hardware_concurrency()).c_str();

	__cilkrts_end_cilk();

	auto start = system_clock::now();

	if (__cilkrts_set_param("nworkers", nthreads) != 0) {
		cerr << "Failed to set worker count\n";
		exit(EXIT_FAILURE);
	}

	__cilkrts_init();

	test(n, &answer);

	__cilkrts_end_cilk();

	auto stop = system_clock::now();

	cout << "Scheduler:  cilk\n";
	cout << "Benchmark:  fib\n";
	cout << "Threads:    " << nthreads << "\n";
	cout << "Time(us):   " << duration_cast<microseconds>(stop - start).count() << "\n";
	cout << "Input:      " << n << "\n";
	cout << "Output:     " << answer << "\n";

	return 0;
}
