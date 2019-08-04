import primitives/c

type
  BoundedQueue*[N: static int, T] = object
    head, tail: int
    buffer: ptr array[N+1, T] # One extra to distinguish between full and empty queues

proc bounded_queue_alloc*(
       T: typedesc,
       capacity: static int
      ): BoundedQueue[capacity, T] {.inline.}=
  result.buffer = cast[ptr array[capacity+1, T]](
    # One extra entry to distinguish full and empty queues
    malloc(T, capacity + 1)
  )
  if result.buffer.isNil:
    raise newException(OutOfMemError, "bounded_queue_alloc failed")

func bounded_queue_free*[N, T](queue: sink BoundedQueue[N, T]) {.inline.}=
  free(queue.buffer)

func bounded_queue_empty(queue: BoundedQueue): bool {.inline.} =
  queue.head == queue.tail

func bounded_queue_full(queue: BoundedQueue): bool {.inline.} =
  (queue.tail + 1) mod (queue.N+1) == queue.head

func bounded_queue_enqueue*[N,T](queue: var BoundedQueue[N,T], elem: sink T){.inline.} =
  assert not queue.bounded_queue_full()

  queue.buffer[queue.tail] = elem
  queue.tail = (queue.tail + 1) mod (N+1)

func bounded_queue_dequeue*[N,T](queue: var BoundedQueue[N,T]): ptr T {.inline.} =
  assert not queue.bounded_queue_empty()

  result = addr queue.buffer[queue.head]
  queue.head = (queue.head + 1) mod (N+1)

func bounded_queue_head*[N,T](queue: BoundedQueue[N,T]): ptr T {.inline.} =
  assert not queue.bounded_queue_empty()
  addr queue.buffer[queue.head]


# --------------------------------------------------------------

when isMainModule:
  var q = bounded_queue_alloc(int, 10)
  var numbers: array[10, int]
  doAssert q.bounded_queue_empty()

  for i in 0 ..< 10:
    numbers[i] = i
    q.bounded_queue_enqueue i

  doAssert q.bounded_queue_full()

  for i in countdown(10, 1):
    let n = q.bounded_queue_dequeue()
    doAssert n[] == numbers[10-i]

  doAssert q.bounded_queue_empty()
  bounded_queue_free(q)
  echo "[SUCCESS]"
