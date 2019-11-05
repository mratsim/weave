# 06 - Implementation of Julia multithreading engine partr
#      Talk: https://www.youtube.com/watch?v=YdiZa0Y3F3c
#      C proof-of-concept: https://github.com/kpamnany/partr
#      See also Julia implementation
#      as the C PoC is missing several advances
#
# Partr is using a "novel" (rediscovered) algorithm for
# scheduling called Parallel Depth First scheduling
# instead of work-stealing.
# Like work-stealing it has excellent theoretical bounds
# but it requires less memory to allocate (dodging the cactus stack?)
# It also exposes inner parallelism with the goal of the authors being
# let's use the scalable inner parallelism of libraries like BLAS
# instead of doing awkward higher level parallelism.
