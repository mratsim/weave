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

#include <cilk/cilk.h>
#include <cilk/cilk_api.h>

using namespace std;
using namespace chrono;

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

double maxerror(elem_t *A, elem_t *B, size_t n)
{
	size_t i, j;
	double error = 0.0;

	for (i = 0; i < n; i++) {
		for (j = 0; j < n; j++) {
			double diff = (A[i * n + j] - B[i * n + j]) / A[i * n + j];
			if (diff < 0)
				diff = -diff;
			if (diff > error)
				error = diff;
		}
	}

	return error;
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


void matmul(
	elem_t *A,
	elem_t *B,
	elem_t *C,
	size_t m,
	size_t n,
	size_t p,
	size_t ld,
	bool add
) {
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

		return;
	}

	if (m >= n && n >= p) {
		size_t m1 = m >> 1;
		cilk_spawn matmul(A, B, C, m1, n, p, ld, add);
		cilk_spawn matmul(A + m1 * ld, B, C + m1 * ld, m - m1, n, p, ld, add);
	} else if (n >= m && n >= p) {
		size_t n1 = n >> 1;
		cilk_spawn matmul(A, B, C, m, n1, p, ld, add);
		cilk_spawn matmul(A + n1, B + n1 * ld, C, m, n - n1, p, ld, true);
	} else {
		size_t p1 = p >> 1;
		cilk_spawn matmul(A, B, C, m, n, p1, ld, add);
		cilk_spawn matmul(A, B + p1, C + p1, m, n, p - p1, ld, add);
	}

	cilk_sync;
}

void test(
	elem_t *A,
	elem_t *B,
	elem_t *C,
	size_t n
) {
	cilk_spawn matmul(A, B, C, n, n, n, n, 0);
	cilk_sync;
}

int main(int argc, char *argv[]) {
	elem_t *A, *B, *C;
	size_t n = 3000;
	const char *nthreads = nullptr;

	if (argc >= 2)
		nthreads = argv[1];
	if (argc >= 3)
		n = atoi(argv[2]);
	if (nthreads == 0)
		nthreads = to_string(thread::hardware_concurrency()).c_str();

	A = new elem_t[n * n];
	B = new elem_t[n * n];
	C = new elem_t[n * n];

	fill(A, n);
	fill(B, n);
	zero(C, n);

	__cilkrts_end_cilk();

	auto start = system_clock::now();

	if (__cilkrts_set_param("nworkers", nthreads) != 0) {
		cerr << "Failed to set worker count\n";
		exit(EXIT_FAILURE);
	}

	__cilkrts_init();

	test(A, B, C, n);

	__cilkrts_end_cilk();

	auto stop = system_clock::now();

	cout << "Scheduler:  cilk\n";
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
