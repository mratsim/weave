#include <iostream>
#include <chrono>
#include <thread>

#include <staccato/include/task.hpp>
#include <staccato/include/scheduler.hpp>

using namespace std;
using namespace chrono;
using namespace staccato;

class FibTask: public task<FibTask>
{
public:
	FibTask (int n_, unsigned long *sum_): n(n_), sum(sum_)
	{ }

	void execute() {
		if (n < 2) {
			*sum = 1;
			return;
		}

		unsigned long x;
		spawn(new(child()) FibTask(n - 1, &x));

		unsigned long y;
		spawn(new(child()) FibTask(n - 2, &y));

		wait();

		*sum = x + y;

		return;
	}

private:
	int n;
	unsigned long *sum;
};

int main(int argc, char *argv[])
{
	size_t n = 40;
	unsigned long answer;
	size_t nthreads = 0;

	if (argc >= 2)
		nthreads = atoi(argv[1]);
	if (argc >= 3)
		n = atoi(argv[2]);
	if (nthreads == 0)
		nthreads = thread::hardware_concurrency();

	auto start = system_clock::now();

	{
		scheduler<FibTask> sh(2, nthreads);
		sh.spawn(new(sh.root()) FibTask(n, &answer));
		sh.wait();
	}

	auto stop = system_clock::now();

	cout << "Scheduler:  staccato\n";
	cout << "Benchmark:  fib\n";
	cout << "Threads:    " << nthreads << "\n";
	cout << "Time(us):   " << duration_cast<microseconds>(stop - start).count() << "\n";
	cout << "Input:      " << n << "\n";
	cout << "Output:     " << answer << "\n";

	return 0;
}
