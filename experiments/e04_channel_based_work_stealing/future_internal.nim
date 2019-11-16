import
  ./channel

when defined(LazyFutures):
  import primitives/c

type
  Channel[T] = channel.Channel[T]
    # We don't want system.Channel

  LazyChan {.union.} = object
    chan*: ChannelRaw
    buf*: array[sizeof(ChannelRaw), byte]

  LazyFutureObj = object
    lazy_chan*: LazyChan
    has_channel*: bool
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
  template future_alloc*(T: typedesc): Future[T] =
    ## Allocated in the stack frame of the caller
    ## This must be a template, for alloca to return a valid
    ## address
    var fut = cast[Future[T]](alloca(LazyFutureObj))
    fut.lazy_chan.chan = nil
    fut.has_channel = false
    fut.isSet = false
    fut


  template future_set*[T](fut: Future[T], res: T) =
    if not fut.has_channel:
      copyMem(fut.lazy_chan.buf.addr, res.unsafeaddr, sizeof(res))
      # TODO: What if sizeof(res) > buffer
      # I suppose res is a pointer we take the address of
      fut.isSet = true
      assert fut.has_channel == false
    else:
      assert not fut.lazy_chan.chan.isNil
      discard channel_send(fut.lazy_chan.chan, res, int32 sizeof(res))

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
