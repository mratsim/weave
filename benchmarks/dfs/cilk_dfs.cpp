
#include <iostream>
#include <vector>
#include <chrono>
#include <thread>

#include <cilk/cilk.h>
#include <cilk/cilk_api.h>

using namespace std;
using namespace chrono;

void dfs(size_t depth, size_t breadth, unsigned long *sum) {
	if (depth == 0) {
		*sum = 1;
		return;
	}

	vector<unsigned long> sums(breadth);

	for (size_t i = 0; i < breadth; ++i)
		cilk_spawn dfs(depth - 1, breadth, &sums[i]);

	cilk_sync;

	*sum = 0;
	for (size_t i = 0; i < breadth; ++i)
		*sum += sums[i];
}

void test(size_t depth, size_t breadth, unsigned long *sum)
{
	cilk_spawn dfs(depth, breadth, sum);
	cilk_sync;
}

int main(int argc, char *argv[])
{
	size_t depth = 8;
	size_t breadth = 8;
	unsigned long answer;
	const char *nthreads = nullptr;

	if (argc >= 2)
		nthreads = argv[1];
	if (argc >= 3)
		depth = atoi(argv[2]);
	if (argc >= 4)
		breadth = atoi(argv[3]);
	if (nthreads == nullptr)
		nthreads = to_string(thread::hardware_concurrency()).c_str();

	__cilkrts_end_cilk();

	auto start = system_clock::now();

	if (__cilkrts_set_param("nworkers", nthreads) != 0) {
		cerr << "Failed to set worker count\n";
		exit(EXIT_FAILURE);
	}

	__cilkrts_init();

	test(depth, breadth, &answer);

	__cilkrts_end_cilk();

	auto stop = system_clock::now();

	cout << "Scheduler:  cilk\n";
	cout << "Benchmark:  dfs\n";
	cout << "Threads:    " << nthreads << "\n";
	cout << "Time(us):   " << duration_cast<microseconds>(stop - start).count() << "\n";
	cout << "Input:      " << depth << " " << breadth << "\n";
	cout << "Output:     " << answer << "\n";

	return 0;
}
