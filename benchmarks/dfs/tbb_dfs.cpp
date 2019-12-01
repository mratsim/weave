#include <iostream>
#include <vector>
#include <chrono>
#include <thread>

#include <tbb/task.h>
#include <tbb/task_scheduler_init.h>

// tbb headers and libtbb must be in your include and library paths.
// Compile with "gcc -O3 -ltbb -lstdc++ benchmarks/dfs/tbb_dfs.cpp"

using namespace std;
using namespace chrono;
using namespace tbb;

class DFSTask: public task
{
public:
	DFSTask (size_t depth_, size_t breadth_, unsigned long *sum_)
		: depth(depth_)
		, breadth(breadth_)
		, sum(sum_)
	{ }

	task *execute() {
		if (depth == 0) {
			*sum = 1;
			return nullptr;
		}

		vector<unsigned long> sums(breadth);

		set_ref_count(breadth + 1);

		for (size_t i = 0; i < breadth; ++i)
			spawn(*new(allocate_child()) DFSTask(depth - 1, breadth, &sums[i]));

		wait_for_all();

		*sum = 0;
		for (size_t i = 0; i < breadth; ++i)
			*sum += sums[i];

		return nullptr;
	}

private:
	size_t depth;
	size_t breadth;
	unsigned long *sum;
};

int main(int argc, char *argv[])
{
	size_t depth = 8;
	size_t breadth = 8;
	unsigned long answer;
	size_t nthreads = 0;

	if (argc >= 2)
		nthreads = atoi(argv[1]);
	if (argc >= 3)
		depth = atoi(argv[2]);
	if (argc >= 4)
		breadth = atoi(argv[3]);
	if (nthreads == 0)
		nthreads = thread::hardware_concurrency();

	auto start = system_clock::now();

	task_scheduler_init scheduler(nthreads);

	auto root = new(task::allocate_root()) DFSTask(depth, breadth, &answer);

	task::spawn_root_and_wait(*root);

	scheduler.terminate();

	auto stop = system_clock::now();

	cout << "Scheduler:  tbb\n";
	cout << "Benchmark:  dfs\n";
	cout << "Threads:    " << nthreads << "\n";
	cout << "Time(us):   " << duration_cast<microseconds>(stop - start).count() << "\n";
	cout << "Input:      " << depth << " " << breadth << "\n";
	cout << "Output:     " << answer << "\n";

	return 0;
}
