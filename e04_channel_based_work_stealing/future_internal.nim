import
  ./channel

when defined(LazyFutures):
  import primitives/c

type
  Channel[T] = channel.Channel[T]
    # We don't want system.Channel

  LazyFutureObj = object
    case has_channel*: bool
    of true:
      chan*: ChannelRaw
    of false:
      buf*: array[sizeof(ChannelRaw), byte]
    isSet*: bool

  # Regular, eagerly allocated futures
when defined(LazyFutures):
  type LazyFuture* = ptr LazyFutureObj
  type Future*[T] = LazyFuture
else:
  type Future*[T] = Channel[T]

# note with lazy futures runtime imports this module
# but it's the contrary with eager futures ...
when defined(LazyFutures):
  proc future_alloc*(T: typedesc): Future[T] {.inline.}=
    ## Allocated in the stack frame of the caller
    result = alloca(LazyFutureObj)
    zeroMem(result, sizeof(result))

  template future_set*[T](fut: Future[T], res: T) =
    if not fut.has_channel:
      copyMem(fut.buf.addr, res.unsafeaddr, sizeof(res))
      # TODO: What if sizeof(res) > buffer
      # I suppose res is a pointer we take the address of
      fut.isSet = true
    else:
      assert not fut.chan.isNil
      discard channel_send(fut.chan, res, int32 sizeof(res))

  template future_get*[T](fut: Future[T], res: var T) =
    RT_force_future(fut, res, int32 sizeof(T))
    # No need to free a channel

else:
  import ./runtime

  proc future_alloc*(T: typedesc): Future[T] {.inline.}=
    ## Returns a future that can hold the
    ## future underlying type
    # Typedesc don't match when passed a type symbol from a macro
    channel_alloc(int32 sizeof(T), 0, Spsc)

  template future_set*[T](fut: Future[T], res: T) =
    discard channel_send(fut, res, int32 sizeof(res))

  template future_get*[T](fut: Future[T], res: var T) =
    RT_force_future(fut, res, int32 sizeof(T))
    channel_free(fut)

  #  template reduce_impl[T](op: untyped, accum: var T): T =
  # Implemented in async internals
