# BPC (Bouncing Producer-Consumer)

From [tasking-2.0](https://github.com/aprell/tasking-2.0) description

> **BPC**, short for **B**ouncing **P**roducer-**C**onsumer benchmark, as far
> as I know, first described by [Dinan et al][1]. There are two types of
> tasks, producer and consumer tasks. Each producer task creates another
> producer task followed by *n* consumer tasks, until a certain depth *d* is
> reached. Consumer tasks run for *t* microseconds. The smaller the values of
> *n* and *t*, the harder it becomes to exploit the available parallelism. A
> solid contender for the most antagonistic microbenchmark.
