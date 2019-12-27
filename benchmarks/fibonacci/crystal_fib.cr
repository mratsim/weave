
# Build with "crystal build --release -Dpreview_mt benchmarks/fibonacci/crystal_fib.cr"
# Run with "CRYSTAL_WORKERS=36 ./crystal_fib" it default to 4

def fib(i : Int32, ch : Channel(Int32) | Nil)
  if i < 2
    return i if ch.nil?
    ch.send(i)
    return 0
  end

  sub_ch = Channel(Int32).new
  spawn fib(i - 1, sub_ch)
  x = fib(i - 2, nil)
  y = sub_ch.receive

  if ch.nil?
    return x + y
  else
    ch.send(x + y)
    return 0
  end
end

i = 0
while i == 0
  puts "Enter the number of fibonacci number to calculate: "
  input = gets
  i = input.to_i if !input.nil?
end

puts "Result ", fib(i, nil)

Fiber.yield
