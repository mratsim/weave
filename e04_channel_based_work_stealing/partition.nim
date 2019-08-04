from ./tasking_internal import ID, num_workers

type
  Partition = object
    number: int32 # index of partition: 0 <= number < partitions
    manager: int32 # ID of partition manager
    workers*: ptr UncheckedArray[int32] # Pointer to statically defined workers
    num_workers*: int32 # Number of statically defined workers
    num_workers_rt*: int32 # Number of workers at runtime

iterator mpairs(p: var Partition): (int32, var int32) =
  # Yields each static worker in the partition
  for i in 0'i32 ..< p.num_workers:
    yield (i, p.workers[i])

template partition_init(N: static int): untyped {.dirty.}=

  var
    partitions {.threadvar.}: array[N, Partition]
    num_partitions* {.threadvar.}: int32
    max_num_partitions {.threadvar.}: int32
    my_partition* {.threadvar.}: ptr Partition
    is_manager* {.threadvar.}: bool
    # Only defined for managers
    # The next manager in the logical chain of managers
    next_manager* {.threadvar.}: int32
    next_worker* {.threadvar.}: int32

  max_num_partitions = N

  proc partition_set*() =
    for i in 0 ..< num_partitions:
      let p = addr partitions[i]
      echo p.num_workers
      for idx, worker in p[].mpairs():
        echo "worker: ", worker
        if worker == ID: # ID is a thread-local var in tasking internals
          my_partition = p
          if worker == p.manager:
            is_manager = true
            if i == num_partitions-1:
              next_manager = partitions[0].manager
            else:
              next_manager = partitions[i+1].manager
          if p.workers[idx+1] == -1:
            next_worker = p.workers[0]
            return
          if p.workers[idx+1] < num_workers: # num_workers is from tasking_internal_init
            next_worker = p.workers[idx+1]
          else:
            next_worker = p.workers[0]
          return

template partition_reset*(): untyped =
  ## Requires partition_init() call
  num_partitions = 0 # from partition_init
  my_partition = nil
  is_manager = false
  next_manager = 0
  next_worker = 0

template partition_create(
            id: untyped,
            N: static int,
            value: typed # static array[N, int32] - commented out as it triggers symbol resolution otherwise
          ): untyped {.dirty.} =
  ## Create a partition of n workers with identifier id
  ## For example:
  ## partition_create(abc, 4): [2, 4, 6, 8]
  ##
  ## At runtime we can assign the partition to a manager:
  ## partition_assign_abc(4)
  ## But we need to make sure that the manager is contained in the partition!
  ## If the manager happens to not be available at runtime, we try to find
  ## another that can fill this role within this partition.
  ## If no worker is available, the partition is unused

  var `partition _ id` {.inject, threadvar.}: array[N+1, int32]
  `partition _ id` = value

  proc `partition_assign _ id`*(manager: int32) =
    echo "Assign, N: ", N
    echo "max_num_partitions: ", max_num_partitions
    echo "num_partitions: ", num_partitions
    echo num_partitions < max_num_partitions
    if num_partitions < max_num_partitions:
      if manager < num_workers:
        let p = addr partitions[num_partitions]
        p.number = num_partitions
        p.manager = manager
        p.workers = cast[ptr UncheckedArray[int32]](addr `partition _ id`)
        p.num_workers = N
        p.num_workers_rt = 0
        inc num_partitions
        echo "Assign workers: ", p.num_workers
      else:
        for i in 0 ..< N:
          if `partition _ id`[i] < num_workers:
            let p = addr partitions[num_partitions]
            p.number = num_partitions
            p.manager = `partition _ id`[i]
            p.workers = cast[ptr UncheckedArray[int32]](addr `partition _ id`)
            p.num_workers = N
            p.num_workers_rt = 0
            inc num_partitions
            # echo &"Changing manager from {manager} to {p.manager}
            return
        # echo &"Partition {num_partitions+1} is empty"

const Partitions {.intdefine.}: range[1 .. 4] = 1
  ## TODO add to compile flag
  ## TODO - Question -> Partitioning algorithm?

partition_init(4)

when Partitions == 1:
  partition_create(all, 48): [
    int32  0,  1,  2,  3,  4,  5,  6,  7,
    8,  9, 10, 11, 12, 13, 14, 15,
    16, 17, 18, 19, 20, 21, 22, 23,
    24, 25, 26, 27, 28, 29, 30, 31,
    32, 33, 34, 35, 36, 37, 38, 39,
    40, 41, 42, 43, 44, 45, 46, 47,
    -1
  ]

  partition_create(large, 64): [
    int32  0,  1,  2,  3,  4,  5,  6,  7,
     8,  9, 10, 11, 12, 13, 14, 15,
    16, 17, 18, 19, 20, 21, 22, 23,
    24, 25, 26, 27, 28, 29, 30, 31,
    32, 33, 34, 35, 36, 37, 38, 39,
    40, 41, 42, 43, 44, 45, 46, 47,
    48, 49, 50, 51, 52, 53, 54, 55,
    56, 57, 58, 59, 60, 61, 62, 63,
    -1
  ]

  partition_create(xlarge, 256): [
    int32 0,   1,   2,   3,   4,   5,   6,   7,
      8,   9,  10,  11,  12,  13,  14,  15,
     16,  17,  18,  19,  20,  21,  22,  23,
     24,  25,  26,  27,  28,  29,  30,  31,
     32,  33,  34,  35,  36,  37,  38,  39,
     40,  41,  42,  43,  44,  45,  46,  47,
     48,  49,  50,  51,  52,  53,  54,  55,
     56,  57,  58,  59,  60,  61,  62,  63,
     64,  65,  66,  67,  68,  69,  70,  71,
     72,  73,  74,  75,  76,  77,  78,  79,
     80,  81,  82,  83,  84,  85,  86,  87,
     88,  89,  90,  91,  92,  93,  94,  95,
     96,  97,  98,  99, 100, 101, 102, 103,
    104, 105, 106, 107, 108, 109, 110, 111,
    112, 113, 114, 115, 116, 117, 118, 119,
    120, 121, 122, 123, 124, 125, 126, 127,
    128, 129, 130, 131, 132, 133, 134, 135,
    136, 137, 138, 139, 140, 141, 142, 143,
    144, 145, 146, 147, 148, 149, 150, 151,
    152, 153, 154, 155, 156, 157, 158, 159,
    160, 161, 162, 163, 164, 165, 166, 167,
    168, 169, 170, 171, 172, 173, 174, 175,
    176, 177, 178, 179, 180, 181, 182, 183,
    184, 185, 186, 187, 188, 189, 190, 191,
    192, 193, 194, 195, 196, 197, 198, 199,
    200, 201, 202, 203, 204, 205, 206, 207,
    208, 209, 210, 211, 212, 213, 214, 215,
    216, 217, 218, 219, 220, 221, 222, 223,
    224, 225, 226, 227, 228, 229, 230, 231,
    232, 233, 234, 235, 236, 237, 238, 239,
    240, 241, 242, 243, 244, 245, 246, 247,
    248, 249, 250, 251, 252, 253, 254, 255,
     -1
  ]

elif Partitions == 2:
  partition_create(west, 24): [
    int32 0,  1,  2,  3,  4,  5, 12, 13,
    14, 15, 16, 17, 24, 25, 26, 27,
    28, 29, 36, 37, 38, 39, 40, 41,
    -1
  ]
  partition_create(east, 24): [
    int32 6,  7,  8,  9, 10, 11, 18, 19,
    20, 21, 22, 23, 30, 31, 32, 33,
    34, 35, 42, 43, 44, 45, 46, 47,
    -1
  ]
  partition_create(X, 128): [
    int32 0,   2,   4,   6,   8,  10,  12,  14,
     16,  18,  20,  22,  24,  26,  28,  30,
     32,  34,  36,  38,  40,  42,  44,  46,
     48,  50,  52,  54,  56,  58,  60,  62,
     64,  66,  68,  70,  72,  74,  76,  78,
     80,  82,  84,  86,  88,  90,  92,  94,
     96,  98, 100, 102, 104, 106, 108, 110,
    112, 114, 116, 118, 120, 122, 124, 126,
    128, 130, 132, 134, 136, 138, 140, 142,
    144, 146, 148, 150, 152, 154, 156, 158,
    160, 162, 164, 166, 168, 170, 172, 174,
    176, 178, 180, 182, 184, 186, 188, 190,
    192, 194, 196, 198, 200, 202, 204, 206,
    208, 210, 212, 214, 216, 218, 220, 222,
    224, 226, 228, 230, 232, 234, 236, 238,
    240, 242, 244, 246, 248, 250, 252, 254,
     -1
  ]
  partition_create(Y, 128): [
    int32 1,   3,   5,   7,   9,  11,  13,  15,
     17,  19,  21,  23,  25,  27,  29,  31,
     33,  35,  37,  39,  41,  43,  45,  47,
     49,  51,  53,  55,  57,  59,  61,  63,
     65,  67,  69,  71,  73,  75,  77,  79,
     81,  83,  85,  87,  89,  91,  93,  95,
     97,  99, 101, 103, 105, 107, 109, 111,
    113, 115, 117, 119, 121, 123, 125, 127,
    129, 131, 133, 135, 137, 139, 141, 143,
    145, 147, 149, 151, 153, 155, 157, 159,
    161, 163, 165, 167, 169, 171, 173, 175,
    177, 179, 181, 183, 185, 187, 189, 191,
    193, 195, 197, 199, 201, 203, 205, 207,
    209, 211, 213, 215, 217, 219, 221, 223,
    225, 227, 229, 231, 233, 235, 237, 239,
    241, 243, 245, 247, 249, 251, 253, 255,
     -1
  ]
  when false:
    partition_create(north, 24): [
      int32 24, 25, 26, 27, 28, 29, 30, 31,
      32, 33, 34, 35, 36, 37, 38, 39,
      40, 41, 42, 43, 44, 45, 46, 47
    ]
    partition_create(south, 24): [
      int32  0,  1,  2,  3,  4,  5,  6,  7,
       8,  9, 10, 11, 12, 13, 14, 15,
      16, 17, 18, 19, 20, 21, 22, 23
    ]
elif Partitions == 3:
  partition_create(A, 12): [
    int32 0,  1,  2,  3,  4,  5,
    12, 13, 14, 15, 16, 17,
    -1
  ]
  partition_create(B, 12): [
    int32 6,  7,  8,  9, 10, 11,
    18, 19, 20, 21, 22, 23,
    -1
  ]
  partition_create(C, 24): [
    int32 24, 25, 26, 27, 28, 29, 30, 31,
    32, 33, 34, 35, 36, 37, 38, 39,
    40, 41, 42, 43, 44, 45, 46, 47,
    -1
  ]
elif Partitions == 4:
  partition_create(Q1, 12): [
    int32 0,  1,  2,  3,  4,  5,
    12, 13, 14, 15, 16, 17,
    -1
  ]
  partition_create(Q2, 12): [
    int32 6,  7,  8,  9, 10, 11,
    18, 19, 20, 21, 22, 23,
    -1
  ]
  partition_create(Q3, 12): [
    int32 24, 25, 26, 27, 28, 29,
    36, 37, 38, 39, 40, 41,
    -1
  ]
  partition_create(Q4, 12): [
    int32 30, 31, 32, 33, 34, 35,
    42, 43, 44, 45, 46, 47,
    -1
  ]
