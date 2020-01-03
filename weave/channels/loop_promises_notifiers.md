## Loop promises notifiers

To support dataflow parallelism (delay tasks until their data dependencies are ready)
you need a way for the producer to notify the consumers.
For simple task this is easy, you only need a broadcast SPMC queue.
Since those are write-once, you don't even need to deque the data

However if the task is a for-loop with for example 100 iterations,
some consumers might be waiting on index 50, some on index 15, ...
We now have the following concerns:

## Producers

- The producers of a loop range are non-deterministic due to work-stealing.
- The order of production is non-deterministic as well.
- There is only one producer per elementary chunk.
- Producers only need to write that their chunk is ready.

## Consumers

- Consumers may wait for different subsets of the whole loop
- Consumers may wait for the whole loop, but start scheduling when a subset is ready
- If we have a parallelFor loop that enqueues a loop task
  then a parallelFor loop that depends on it, all the dependent tasks will
  be held by the worker which encountered that.
- They want to schedule as many dependent tasks as possible in a single pass
  to maintain the busy-leaves property i.e. if as long as there is work, workers are active
  a greedy scheduler (a scheduler that maintains the busy-leaves property) is at most
  2x slower than the theoretical optimal schedule.

## Cost-analysis

### Producers

Producers' cost is n * update-cost distributed on all producers.
I.e. if the producer data structure is an array it's O(n / P), if it's a tree it's O(n log(n) / P).

### Consumers

- If the producers data structure is a sequence/array, the consumer can access any element in O(1) time
  however blindly scanning for a ready task is O(n). In that case, the best strategy is for consumer
  to start from their pending dependent tasks and check if they are ready. If we want to check all tasks
  to schedule as many as possible this is O(n) independent of the number of actually dispatchable tasks (it could be 0 or
  n). Then the cost is O(M * n) with M a factor dependent on how often a worker checks its potentially ready tasks.

- Alternatively if the producers data-structure is a binary tree, the consumer can access any element in O(log(n))
  time. Checking if any task is available can be made O(1)
  so the O(log(n)) cost is only paid when it will be useful and once per possible tasks so 0(n log(n)) producer tree accesses total.
  In that case, consumer should have a mirror tree with "dispatched" dependent tasks.
  If we can dispatch k tasks at one time the cost is O(k log(N)), the cost is only paid when useful.
  We also have O(n log(n)) consumer tree accesses in total.
  The cumulated consumer cost is O(2n log(n)), this is true indepently of how often a consumer checks its ready tasks.

In both cases the space cost is O(n)

### Optimization

Due to the bounded worst-case performance of the binary-tree solution, I lean toward that.
However, what if all the dependent tasks or a large contiguous proportion (half) are ready?
It seems like a waste to start from the root of the tree every time.

I sense there is an optimization to be done. For example,
the search for promises could return [start, stop), the largest contiguous
available promise range.
This changes the costs to:
- if n tasks are ready: cost is O(1)
- if only 1 task is ever ready at a time: cost is O(n log(n)) (amortized over n checks, same as baseline)
- if half the tasks are ready, none contiguous: cost is O(2 * n/2 log(n)) (2 costly instances of n/2 log(n) retrievals, same as baseline)
- otherwise this can be significantly more efficient than the baseline o(n log(n)) cumulated cost

It is however very important to keep memory usage bounded at O(n)
as any increased memory usage will be scaled by the number of dependent tasks,
i.e. introducing an extra int32 field per node doubles the memory requirement.
If 2 tasks are dependent on that promise it's 4x the memory usage ...

Even worse allocating/releasing memory from a random thread
is probably the single biggest source of overhead in a multithreaded runtime (the main reason why LazyFlowvar allocated on the stack with `alloca` exist)
Assuming we find a way to go from O(n log(n)) binary-tree access to O(log(n)),
if the cost is O(2n) memory space, we win locally but will pay it dearly in memory management overhead.

## Implementation

The following is a thread-local implementation of the binary tree solution.
Assume that in the runtime, for producers we will have a ptr object with atomic reference count instead of a ref object
and the "fulfilled" field will be a seq of atomics.

```Nim
# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import sequtils

# Producers' side
# ----------------------------------------------------

# Note, for this example, the producer and consumer are on the same thread
# In the actual implementation, "ProducersRangePromises"
# must be atomicRefCounted and the items in fulfilled must be atomic as well.

type
  ProducersRangePromises = ref object
    ## This is a "concurrent" binary array tree
    ## that holds promises over a for-loop range.
    ## The producers which fulfill a promise updates this tree.
    # In the threaded-case, this is easily thread-safe as only monotonic increment are used
    # The main issue is false-sharing / cache-ping pong if many thread are fulfilling
    # promises stored in the same cache lin, but padding would be very memory inefficient.
    start, stop, stride: int32
    fulfilled: seq[int32]

proc newPromiseRange(start, stop, stride: int32): ProducersRangePromises =
  assert stop > start
  assert stride > 0

  new result
  result.start = start
  result.stop = stop
  result.stride = stride

  let bufLen = (result.stop - result.start + result.stride-1) div result.stride
  result.fulfilled.newSeq(bufLen)

proc getInternalIndex(pr: ProducersRangePromises, iterIndex: int32): int32 {.inline.} =
  assert iterIndex in pr.start ..< pr.stop
  result = (iterIndex - pr.start) div pr.stride

proc len(pr: ProducersRangePromises): int32 {.inline.} =
  pr.fulfilled.len.int32

proc ready*(pr: ProducersRangePromises, index: int32) =
  ## requires the public iteration index in [start, stop) range.
  assert index in pr.start ..< pr.stop
  var idx = pr.getInternalIndex(index)

  while idx != 0:
    pr.fulfilled[idx] += 1
    idx = (idx-1) shr 1

  pr.fulfilled[0] += 1

# Consumers' side
# ----------------------------------------------------

type
  ConsumerRangeDelayedTasks = object
    ## A Range-delayed task is a task that is dependent on a loop range.
    ## The consumer will schedule those tasks piece by piece as they become available.
    ## The consumer keeps track of tasks already dispatched and the ready tasks published by the producer.
    ## This is thread-local. Many consumer can depend on the same producers' promises.
    ## The last one should release ProducersPromises memory.
    promises: ProducersRangePromises
    dispatched: seq[int32]

proc newConsumerRangeDelayedTasks(pr: ProducersRangePromises): ConsumerRangeDelayedTasks =
  result.promises = pr
  result.dispatched.newSeq(pr.fulfilled.len)

proc dispatch*(cr: var ConsumerRangeDelayedTasks, internalIndex: int32) =
  ## requires the internal index in [0, dispatched.len) range.
  var idx = internalIndex

  while idx != 0:
    cr.dispatched[idx] += 1
    idx = (idx-1) shr 1

  cr.dispatched[0] += 1

proc anyAvailable(cr: ConsumerRangeDelayedTasks, index: int32): bool {.inline.} =
  let pr = cr.promises
  if index >= pr.len:
    return false
  return pr.fulfilled[index] > cr.dispatched[index]

proc anyFulfilled*(cr: var ConsumerRangeDelayedTasks): tuple[foundNew: bool, index: int32] =
  ## This search for a fulfilled promise that wasn't already
  ## dispatched.
  ## If it finds one, it will be marked dispatched and its internal index will be returned.
  while true:
    # 3 cases (non-exclusive)
    #   1. there is an availability in the left subtree
    #   2. there is an availability in the right subtree
    #   3. the current node is available
    let left = 2*result.index + 1
    let right = left + 1
    if cr.anyAvailable(left):
      result.index = left
    elif cr.anyAvailable(right):
      result.index = right
    elif cr.anyAvailable(result.index):
      # The current node is available and none of the children are
      break
    else:
      assert result.foundNew == false
      return

  # We found an available node, update the dispatch tree
  result.foundNew = true
  assert result.index in 0 ..< cr.dispatched.len
  cr.dispatch(result.index)

when isMainModule:
  # block:
  #   let pr = newPromiseRange(32, 128, 32)
  #   for i in 32'i32..< 128:
  #     echo "i: ", i, ", internalIndex: ", pr.getInternalIndex(i)

  block:
    let pr = newPromiseRange(0, 10, 1)
    var cr = newConsumerRangeDelayedTasks(pr)
    echo pr[]

    echo "Adding 7"
    pr.ready(7)
    echo pr[]

    block:
      let promise = cr.anyFulfilled()
      echo "searching for promise: ", promise

    block:
      let promise = cr.anyFulfilled()
      echo "searching for promise: ", promise

    echo "Adding [2, 0]"
    pr.ready(2)
    pr.ready(0)

    block:
      let promise = cr.anyFulfilled()
      echo "searching for promise: ", promise

    echo "Adding [3, 4]"
    pr.ready(3)
    pr.ready(4)

    block:
      let promise = cr.anyFulfilled()
      echo "searching for promise: ", promise

    block:
      let promise = cr.anyFulfilled()
      echo "searching for promise: ", promise

    block:
      let promise = cr.anyFulfilled()
      echo "searching for promise: ", promise

    block:
      let promise = cr.anyFulfilled()
      echo "searching for promise: ", promise

    block:
      let promise = cr.anyFulfilled()
      echo "searching for promise: ", promise
```
