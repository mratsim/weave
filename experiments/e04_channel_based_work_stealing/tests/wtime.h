#ifndef WTIME_H
#define WTIME_H

#include <sys/time.h>
#include <time.h>

// Number of seconds since the Epoch
static inline double Wtime_sec(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return tv.tv_sec + tv.tv_usec / 1e6;
}

// Number of milliseconds since the Epoch
static inline double Wtime_msec(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return tv.tv_sec * 1e3 + tv.tv_usec / 1e3;
}

// Number of microseconds since the Epoch
static inline double Wtime_usec(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);
	return tv.tv_sec * 1e6 + tv.tv_usec;
}

// Read time stamp counter on x86
static inline unsigned long long readtsc(void)
{
	unsigned int lo, hi;
	// RDTSC copies contents of 64-bit TSC into EDX:EAX
	asm volatile ("rdtsc" : "=a" (lo), "=d" (hi));
 	return (unsigned long long)hi << 32 | lo;
}

#define WTIME_unique_var_name_paste(id, n) id ## n
#define WTIME_unique_var_name(id, n) WTIME_unique_var_name_paste(id, n)
#define WTIME_unique_var(id) WTIME_unique_var_name(id, __LINE__)

// Convenience macro for time measurement
#define WTIME(unit) \
	double WTIME_unique_var(_start_##unit##_) = Wtime_##unit##ec(); \
	int WTIME_unique_var(_i_) = 0; \
	for (; WTIME_unique_var(_i_) == 0 || \
		 (printf("Elapsed wall time: %.2lf "#unit"\n", \
			     Wtime_##unit##ec() - WTIME_unique_var(_start_##unit##_)), 0); \
		 WTIME_unique_var(_i_)++)

#endif // WTIME_H
