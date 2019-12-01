/*
 * Rectangular matrix multiplication.
 *
 * Adapted from Cilk 5.4.3 example
 *
 * https://bradley.csail.mit.edu/svn/repos/cilk/5.4.3/examples/matmul.cilk;
 * See the paper ``Cache-Oblivious Algorithms'', by
 * Matteo Frigo, Charles E. Leiserson, Harald Prokop, and
 * Sridhar Ramachandran, FOCS 1999, for an explanation of
 * why this algorithm is good for caches.
 *
 */

#include <iostream>
#include <chrono>
#include <thread>
#include <cmath>

#include <tbb/task.h>
#include <tbb/task_scheduler_init.h>

// tbb headers and libtbb must be in your include and library paths.
// Compile with "gcc -O3 -ltbb -lstdc++ benchmarks/matmul_cache_oblivious/tbb_matmul_co.cpp"

using namespace std;
using namespace chrono;
using namespace tbb;

typedef float elem_t;

inline uint32_t xorshift_rand() {
	static uint32_t x = 2463534242;
	x ^= x >> 13;
	x ^= x << 17;
	x ^= x >> 5;
	return x;
}

void zero(elem_t *A, size_t n)
{
	for (size_t i = 0; i < n; ++i)
		for (size_t j = 0; j < n; ++j)
			A[i * n + j] = 0.0;
}

void fill(elem_t *A, size_t n)
{
	for (size_t i = 0; i < n; ++i)
		for (size_t j = 0; j < n; ++j)
			A[i * n + j] = xorshift_rand() % n;
}

bool check(elem_t *A, elem_t *B, elem_t *C, size_t n)
{
	elem_t tr_C = 0;
	elem_t tr_AB = 0;
	for (size_t i = 0; i < n; ++i) {
		for (size_t j = 0; j < n; ++j)
			tr_AB += A[i * n + j] * B[j * n + i];
		tr_C += C[i * n + i];
	}

	return fabs(tr_AB - tr_C) < 1e-3;
}

class MultTask: public task
{
public:
	MultTask(
		elem_t *A,
		elem_t *B,
		elem_t *C,
		size_t m,
		size_t n,
		size_t p,
		size_t ld,
		bool add)
	: A(A)
	, B(B)
	, C(C)
	, m(m)
	, n(n)
	, p(p)
	, ld(ld)
	, add(add)
	{ };

	task *execute() {
		if ((m + n + p) <= 64) {
			if (add) {
				for (size_t i = 0; i < m; ++i) {
					for (size_t k = 0; k < p; ++k) {
						elem_t c = 0.0;
						for (size_t j = 0; j < n; ++j)
							c += A[i * ld + j] * B[j * ld + k];
						C[i * ld + k] += c;
					}
				}
			} else {
				for (size_t i = 0; i < m; ++i) {
					for (size_t k = 0; k < p; ++k) {
						elem_t c = 0.0;
						for (size_t j = 0; j < n; ++j)
							c += A[i * ld + j] * B[j * ld + k];
						C[i * ld + k] = c;
					}
				}
			}

			return nullptr;
		}

		if (m >= n && n >= p) {
			size_t m1 = m >> 1;
			MultTask &a = *new(allocate_child())
				MultTask(A, B, C, m1, n, p, ld, add);
			MultTask &b = *new(allocate_child())
				MultTask(A + m1 * ld, B, C + m1 * ld, m - m1, n, p, ld, add);

			set_ref_count(3);

			spawn(a);
			spawn(b);
		} else if (n >= m && n >= p) {
			size_t n1 = n >> 1;
			MultTask &a = *new(allocate_child())
				MultTask(A, B, C, m, n1, p, ld, add);
			MultTask &b = *new(allocate_child())
				MultTask(A + n1, B + n1 * ld, C, m, n - n1, p, ld, true);

			set_ref_count(3);

			spawn(a);
			spawn(b);
		} else {
			size_t p1 = p >> 1;
			MultTask &a = *new(allocate_child())
				MultTask(A, B, C, m, n, p1, ld, add);
			MultTask &b = *new(allocate_child())
				MultTask(A, B + p1, C + p1, m, n, p - p1, ld, add);

			set_ref_count(3);

			spawn(a);
			spawn(b);
		}

		wait_for_all();

		return nullptr;
	}

private:
	elem_t *A;
	elem_t *B;
	elem_t *C;
	size_t m;
	size_t n;
	size_t p;
	size_t ld;
	bool add;
};

int main(int argc, char *argv[]) {
	elem_t *A, *B, *C;
	size_t n = 3000;
	size_t nthreads = 0;

	if (argc >= 2)
		nthreads = atoi(argv[1]);
	if (argc >= 3)
		n = atoi(argv[2]);
	if (nthreads == 0)
		nthreads = thread::hardware_concurrency();

	A = new elem_t[n * n];
	B = new elem_t[n * n];
	C = new elem_t[n * n];

	fill(A, n);
	fill(B, n);
	zero(C, n);

	auto start = system_clock::now();

	task_scheduler_init scheduler(nthreads);

	auto root = new(task::allocate_root()) MultTask(A, B, C, n, n, n, n, 0);

	task::spawn_root_and_wait(*root);

	scheduler.terminate();

	auto stop = system_clock::now();

	cout << "Scheduler:  tbb\n";
	cout << "Benchmark:  matmul\n";
	cout << "Threads:    " << nthreads << "\n";
	cout << "Time(us):   " << duration_cast<microseconds>(stop - start).count() << "\n";
	cout << "Input:      " << n << "\n";
	cout << "Output:     " << check(A, B, C, n) << "\n";

	delete []C;
	delete []B;
	delete []A;
	return 0;
}
