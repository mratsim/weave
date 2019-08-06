import
  ./channel

type
  Channel[T] = channel.Channel[T]
    # We don't want system.Channel

  LazyFutureObj[T] = object
    case has_channel: bool
    of true:
      chan: Channel[T]
    of false:
      buf: array[sizeof(Channel[T]), byte]

  LazyFuture[T] = ptr LazyFutureObj[T]

  # Regular, eagerly allocated futures
  Future*[T] = Channel[T]

# note with lazy futures runtime imports this module
# but it's the contrary with eager futures ...
when defined(LazyFuture):
  discard # TODO
else:
  import ./runtime

  proc future_alloc*(T: typedesc): Future[T] =
    ## Returns a future that can hold the
    ## future underlying type
    # Typedesc don't match when passed a type symbol from a macro
    channel_alloc(int32 sizeof(T), 0, Spsc)

  proc future_set*[T](fut: Future[T], res: T) =
    discard channel_send(fut, res, int32 sizeof(res))

  proc future_get*[T](fut: Future, res: var T) =
    RT_force_future(fut, res, sizeof(T))
    channel_free(fut)

  #  template reduce_impl[T](op: untyped, accum: var T): T =
  # Implemented in async internals
