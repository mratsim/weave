import
  ./channel

type
  Channel = channel.Channel
    # We don't want system.Channel

  LazyFutureObj = object
    case has_channel: bool
    of true:
      chan: Channel
    of false:
      buf: array[sizeof(Channel), byte]

  LazyFuture = ptr LazyFutureObj

  # Regular, eagerly allocated futures
  Future = Channel

# note with lazy futures runtime imports this module
# but it's the contrary with eager futures ...
when defined(LazyFuture):
  discard # TODO
else:
  import ./runtime

  proc future_alloc*(T: typedesc): Future =
    # Returns a future that can hold the
    # future underlying type
    channel_alloc(sizeof(T), 0, Spsc)

  proc future_set*[T](fut: Future, res: var T) =
    channel_send(fut, res, sizeof(res))

  proc future_get*[T](fut: Future, res: var T) =
    RT_force_future(fut, res, sizeof(T))
    channel_free(fut)

  #  template reduce_impl[T](op: untyped, accum: var T): T =
  # Implemented in async internals
