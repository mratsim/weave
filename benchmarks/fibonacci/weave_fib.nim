import ../../weave

proc fib(n: int): int =
  # int64 on x86-64
  if n < 2:
    return n

  let x = spawn fib(n-1)
  let y = fib(n-2)

  result = sync(x) + y

proc main() =
  init(Weave)

  let f = fib(40)

  sync(Weave)
  exit(Weave)

  echo f

main()
