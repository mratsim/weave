# 01 - Experiment by storing tasks content as an object instead of
#      a pointer or closure:
#      - to limit memory fragmentation and cache misses
#      - avoid having to deallocate the pointer/closure

# import
#   # Low-level primitives
#   system/atomics

# Constants
# ----------------------------------------------------------------------

const
  PageAlignment = 1024
  CacheLineSize = 64 # Some Samsung phone have 128 bytes cache line
                     # This is necessary to avoid cache invalidation / false sharing
                     # when many cores read/write in the same cache line

# Types
# ----------------------------------------------------------------------

type
  StackAllocator = object
    ## Pages are pushed and popped from the last of the stack
    pageSize: int
    last: ptr Page
    first: ptr Page

  Page = object
    ## Metadata prepended to the Allocator pages
    ## Pages track the next page
    ## And works as a stack allocator within the page
    next: ptr Page
    freeSpace: int
    top: pointer    # pointer to the last of the stack
    bottom: pointer # pointer to the first of the stack

# Utils
# ----------------------------------------------------------------------

func isPowerOf2(n: int): bool =
  (n and (n-1)) == 0

func round_step_down*(x: Natural, step: static Natural): int {.inline.} =
  ## Round the input to the previous multiple of "step"
  when step.isPowerOf2():
    # Step is a power of 2. (If compiler cannot prove that x>0 it does not make the optim)
    result = x and not(step - 1)
  else:
    result = x - x mod step

func round_step_up*(x: Natural, step: static Natural): int {.inline.} =
  ## Round the input to the next multiple of "step"
  when step.isPowerOf2():
    # Step is a power of 2. (If compiler cannot prove that x>0 it does not make the optim)
    result = (x + step - 1) and not(step - 1)
  else:
    result = ((x + step - 1) div step) * step

# Memory
# ----------------------------------------------------------------------

proc posix_memalign(mem: var ptr Page, alignment, size: csize){.sideeffect,importc, header:"<stdlib.h>".}
proc free(mem: sink pointer){.sideeffect,importc, header:"<stdlib.h>".}

func initPage(mem: pointer, size: int): Page =
  Page(
    next: nil,
    freeSpace: size,
    top: mem,
    bottom: cast[pointer](cast[ByteAddress](mem) +% sizeof(Page))
  )

func align(alignment: static[int], size: int, buffer: var pointer, space: var int): pointer =
  ## Tries to get ``size`` of storage with the specified ``alignment``
  ## from a ``buffer`` of ``space`` size
  ##
  ## ``alignment``: specified alignment
  ## ``size``: desired size
  ## ``buffer``: pointer to the buffer holding the storage
  ## ``space``: space of that buffer
  ##
  ## If the aligned storage fit the buffer, its pointer is updated
  ## to the first byte of aligned storage and space is reduced by the bytes
  ## used for alignment
  ##
  ## Returns either an aligned pointer in the passed buffer or nil if it fails.
  static: doAssert isPowerOf2(alignment), $alignment & " is not a power of 2"
  let
    address = cast[ByteAddress](buffer)
    aligned = (address - 1 + alignment) and -alignment
    offset = aligned - address
  if size + offset > space:
    return nil
  else:
    space -= offset
    buffer = cast[pointer](aligned)
    return aligned

func alloc(page: var Page, alignment: static[int], size: int): pointer =
  ## Allocate a memory buffer within a page
  ## Returns nil if allocation failed
  static: doAssert isPowerOf2(alignment), $alignment & " is not a power of 2"

  result = align(alignment, size, page.bottom, page.freeSpace)
  if result.isNil:
    return
  page.bottom = cast[pointer](cast[ByteAddress](page.bottom) +% size)
  page.freeSpace -= size

proc allocate_page(alignment: static[int], size: int): ptr Page =
  ## Allocate a page
  ## Create a page metadata object at the start of the page
  ## that manages the memory within

  # Posix memalign requires size to be a power of 2
  static: doAssert isPowerOf2(alignment), $alignment & " is not a power of 2"
  let sizeUp = round_step_up(size, alignment)
  posix_memalign(result, alignment, sizeUp)

  # TODO: __mingw_aligned_malloc and _aligned_malloc on Win32
  # Or just request OS pages with mmap

  # Initialize the page metadata
  result[] = initPage(result, sizeUp - sizeof(Page))

proc initStackAllocator(pageSize: int): StackAllocator =
  result.pageSize = pagesize
  result.first = allocate_page(PageAlignment, pageSize)
  result.last = result.first

proc `=destroy`(al: var StackAllocator) =
  var node = al.last
  while not node.isNil:
    let p = node
    node = node.next
    free(p)

proc grow(al: var StackAllocator, required_size: int) =
  let size = max(al.pageSize, required_size)
  let p = allocate_page(PageAlignment, size)

  al.last.next = p
  al.last = p

proc alloc(al: var StackAllocator, alignment: static[int], size: int): pointer =
  result = al.last.alloc(alignment, size)
  if not result.isNil:
    return

  # OOM in page
  al.grow(size)

  # Retry
  result = al.last.alloc(alignment, size)

  if result.isNil:
    # Give up - note that if this is not done in the master thread
    #           a thread-local GC needs to be allocated
    raise newException(OutOfMemError, "Unable to allocate memory")

proc alloc(al: var StackAllocator, T: typedesc): ptr T =
  result = al.alloc(alignof(T), sizeof(T))

proc allocArray(al: var StackAllocator, T: typedesc, length: int): ptr UncheckedArray[T] =
  result = al.alloc(alignof(T), sizeof(T) * length)
