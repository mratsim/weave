# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import ./intrusive_stacks

type
  StealableTask* = concept x, var v
    # x is a ptr object and has a next field
    x is IntrusiveStackable
    # x has a "fn" field with the proc to run
    x.fn is proc (param: pointer) {.nimcall.}
    # var x has allocate proc
    allocate(v)
    # x has delete proc
    delete(x)

    # TODO: closures instead of nimcall would be much nicer and would
    # allow syntax like:
    #
    # var myArray: ptr UncheckedArray[int]
    # parallel_loop(i, 0, 100000):
    #   myArray[i] = i
    #
    # with "myArray" implicitly captured.

  PrellDeque*[T: StealableTask] = object
    ## Private Work-Stealing Deque
    ## from PhD Thesis
    ##
    ## Embracing Explicit Communication in Work-Stealing Runtime Systems
    ## Andreas Prell, 2016
    ## https://epub.uni-bayreuth.de/2990/1/main_final.pdf
    ##
    ## This is a thread-local work-stealing deque (unlike concurrent Chase-Lev deque)
    ## for multithreading runtimes that do not use shared-memory
    ## for inter-thread communication.
    ##
    ## PrellDeque implements the traditional work-stealing deque:
    ## - addLast (push)
    ## - popLast (pop)
    ## - popFirst (steal)
    ##
    ## But as there is no thread contention, it also provides several extras:
    ## - adding multiple tasks at once
    ## - stealing one, half or an arbitrary number in-between
    ## - No need for complex formal verification of the deque
    ##   Formal verification and testing of queues is much more common.
    ##
    ## Channels/concurrent queues have much more research than
    ## concurrent deque and larger hardware support as they don't require atomics.
    ## Some hardware even provides message passing primitives.
    ##
    ## Channels also scale to clusters, as they are the only way to communicate
    ## between 2 machines (like MPI).
    ##
    ## The main drawback is the need to poll the communication channel, introducing latency,
    ## and requiring a backoff mechanism.

    head, tail: T
    pending_tasks*: int32
    # num_steals: int
    freelist: IntrusiveStack[T]

# Basic deque routines
# ---------------------------------------------------------------

func isEmpty*(dq: PrellDeque): bool {.inline.} =
  # when empty dq.head == dq.tail == dummy node
  (dq.head == dq.tail) and (dq.pending_tasks == 0)

func addLast*[T](dq: PrellDeque[T], task: sink T) =
  ## Append a task to the end of the deque
  assert not task.isNil

  task.next = dq.tail
  dq.tail.prev = task
  dq.tail = task

  dq.pending_tasks += 1

func popLast*[T](dq: PrellDeque): T =
  ## Pop the last task from the deque
  if dq.isEmpty():
    return nil

  result = dq.tail
  dq.tail = dq.tail.next
  dq.tail.prev = nil
  result.next = nil

  dq.pending_tasks -= 1

# Creation / Destruction
# ---------------------------------------------------------------

func newPrellDeque*(T: typedesc[StealableTask]): PrellDeque[T] {.noinit.} =
  result.head.allocate()
  # Dummy to easily assert things going wrong
  result.head.fn = cast[proc (param: pointer){.nimcall.}](ByteAddress 0xCAFE)
  result.tail = result.head
  result.pending_tasks = 0
  # result.num_steals = 0
  result.freelist = default(IntrusiveStack[T])

func `=destroy`[T](dq: var PrellDeque[T]) =
  # Free all remaining tasks
  while (let task = dq.popLast(); not task.isNil):
    delete(task)
  assert dq.pending_tasks == 0
  assert dq.isEmpty
  # Free dummy node
  delete(dq.head)
  # Free cache
  `=destroy`(dq.freelist)
