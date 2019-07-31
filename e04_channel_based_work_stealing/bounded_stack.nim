import primitives/c

type
  BoundedStack[N: static int, T] = object
    top: int
    buffer: ptr array[N, T]

proc bounded_stack_alloc(
       T: typedesc,
       capacity: static int
     ): BoundedStack[capacity, T] {.inline.} =
  result.buffer = cast[ptr array[capacity, T]](
    malloc(T, capacity)
  )
  if result.buffer.isNil:
    raise newException(OutOfMemError, "bounded_stack_alloc failed")

func bounded_stack_free(stack: BoundedStack) {.inline.} =
  free(stack.buffer)

func bounded_stack_empty(stack: BoundedStack): bool {.inline.} =
  stack.top == 0

func bounded_stack_full(stack: BoundedStack): bool {.inline.} =
  stack.top == stack.N

func bounded_stack_push[N, T](stack: var BoundedStack[N, T], elem: T) {.inline.} =
  assert not stack.bounded_stack_full()
  stack.buffer[stack.top] = elem
  inc stack.top

func bounded_stack_pop[N, T](stack: var BoundedStack[N, T]): T {.inline.} =
  assert not stack.bounded_stack_empty()
  dec stack.top
  return stack.buffer[stack.top]

# --------------------------------------------------------------

when isMainModule:
  var s = bounded_stack_alloc(int, 10)
  var numbers: array[10, int]
  doAssert s.bounded_stack_empty()

  for i in 0 ..< 10:
    numbers[i] = i
    s.bounded_stack_push i

  doAssert s.bounded_stack_full()

  for i in countdown(10, 1):
    let n = s.bounded_stack_pop()
    doAssert n == numbers[i-1]

  doAssert s.bounded_stack_empty()
  bounded_stack_free(s)
  echo "[SUCCESS]"
