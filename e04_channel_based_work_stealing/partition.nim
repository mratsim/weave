type
  Partition = object
    number: int32 # index of partition: 0 <= number < partitions
    manager: int32 # ID of partition manager
    workers: ptr UncheckedArray[int32] # Pointer to statically defined workers
    num_workers: int32 # Number of statically defined workers
    num_workers_rt: int32 # Number of workers at runtime

iterator mpairs(p: var Partition): (int32, var int32) =
  # Yields each static worker in the partition
  for i in 0'i32 ..< p.num_workers:
    yield (i, p.workers[i])

template partition_init(N: static int): untyped {.dirty.}=

  var
    partitions {.threadvar.}: array[N, Partition]
    num_partitions {.threadvar.}: int32
    max_num_partitions {.threadvar.}: int32
    my_partition {.threadvar.}: ptr Partition
    is_manager {.threadvar.}: bool
    # Only defined for managers
    # The next manager in the logical chain of managers
    next_manager {.threadvar.}: int32
    next_worker {.threadvar.}: int32

  num_partitions = N
  max_num_partitions = N

  proc partition_set() =
    for i in 0 ..< num_partitions:
      let p = partitions[i].addr
      for idx, worker in p[].mpairs():
        if worker == ID: # ID is a thread-local var in the runtime
          my_partition = p
          if worker == p.manager:
            is_manager = true
            if i == num_partitions-1:
              next_manager = partitions[0].manager
            else:
              next_manager = partitions[i+1].manager
          if p.worker[idx+1] == -1:
            next_worker = p.workers[0]
            return
          if p.worker[idx+1] < num_workers: # num_workers is from tasking_internel_init
            next_worker = p.worker[idx+1]
          else:
            next_worker = p.workers[0]
          return
