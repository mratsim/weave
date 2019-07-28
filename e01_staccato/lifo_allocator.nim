# Constants
# ----------------------------------------------------------------------

const
  PageAlignment = 1024
  CacheLineSize = 64 # Some Samsung phone have 128 bytes cache line
                     # This is necessary to avoid cache invalidation / false sharing
                     # when many cores read/write in the same cache line

type
  # Memory
  # --------------------------------------------------------------------

  LifoAllocator* = object
    ## Pages are pushed and popped from the last of the stack.
    ## Note: on destruction, pages are deallocated from first to last.
    m_page_size*: int
    m_head*: ptr Page
    m_tail*: ptr Page

  Page = object
    ## Metadata prepended to the Allocator pages
    ## Pages track the next page
    ## And works as a stack allocator within the page
    m_next: ptr Page
    m_size_left: int
    m_stack: pointer # pointer to the last of the stack
    m_base: pointer # pointer to the first of the stack

# Utils
# ----------------------------------------------------------------------

func isPowerOf2(n: int): bool =
  (n and (n-1)) == 0

func round_step_down(x: Natural, step: static Natural): int {.inline.} =
  ## Round the input to the previous multiple of "step"
  when step.isPowerOf2():
    # Step is a power of 2. (If compiler cannot prove that x>0 it does not make the optim)
    result = x and not(step - 1)
  else:
    result = x - x mod step

func round_step_up(x: Natural, step: static Natural): int {.inline.} =
  ## Round the input to the next multiple of "step"
  when step.isPowerOf2():
    # Step is a power of 2. (If compiler cannot prove that x>0 it does not make the optim)
    result = (x + step - 1) and not(step - 1)
  else:
    result = ((x + step - 1) div step) * step

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

# Memory
# ----------------------------------------------------------------------
# A Practical Solution to the Cactus Stack Problem
# http://chaoran.me/assets/pdf/ws-spaa16.pdf

proc posix_memalign(mem: var ptr Page, alignment, size: csize){.sideeffect,importc, header:"<stdlib.h>".}
proc free(mem: sink pointer){.sideeffect,importc, header:"<stdlib.h>".}

func initPage(mem: pointer, size: int): Page =
  result.m_size_left = size
  result.m_stack = mem
  result.m_base = cast[pointer](cast[ByteAddress](mem) +% sizeof(Page))

func set_next(page: var Page or ptr Page, next_page: ptr Page) {.inline.} =
  page.m_next = next_page

func get_next(page: Page or ptr Page): ptr Page {.inline.} =
  page.m_next

func alloc(page: var Page, alignment: static[int], size: int): pointer =
  ## Allocate a memory buffer within a page
  ## Returns nil if allocation failed
  static: doAssert isPowerOf2(alignment), $alignment & " is not a power of 2"

  result = align(alignment, size, page.m_base, page.m_size_left)
  if result.isNil:
    return
  page.m_base = cast[pointer](cast[ByteAddress](page.m_base) +% size)
  page.m_size_left -= size

proc allocate_page(alignment: static[int], size: int): ptr Page =
  ## Allocate a page
  ## Create a page metadata object at the start of the page
  ## that manages the memory within

  # Posix memalign requires size to be a power of 2
  static: doAssert isPowerOf2(alignment), $alignment & " is not a power of 2"
  let sz = round_step_up(size, alignment)
  posix_memalign(result, alignment, sz)

  # TODO: __mingw_aligned_malloc and _aligned_malloc on Win32
  # Or just request OS pages with mmap

  # Initialize the page metadata
  result[] = initPage(result, sz - sizeof(Page))

proc initLifoAllocator(page_size: int): LifoAllocator =
  result.m_page_size = page_size
  result.m_head = allocate_page(PageAlignment, page_size)
  result.m_tail = result.m_head

proc `=destroy`(al: var LifoAllocator) =
  var n = al.m_head
  while not n.isNil:
    let p = n
    n = n.get_next()
    free(p)

proc inc_tail(al: var LifoAllocator, required_size: int) =
  let size = max(al.m_page_size, required_size)
  let p = allocate_page(PageAlignment, size)

  al.m_tail.set_next(p)
  al.m_tail = p

proc alloc(al: var LifoAllocator, alignment: static[int], size: int): pointer =
  result = al.m_tail.alloc(alignment, size)
  if not result.isNil:
    return

  # OOM in page
  al.inc_tail(size)

  # Retry
  result = al.m_tail.alloc(alignment, size)

  if result.isNil:
    # Give up - note that if this is not done in the master thread
    #           a thread-local GC needs to be allocated
    raise newException(OutOfMemError, "Unable to allocate memory")

proc alloc(al: var LifoAllocator, T: typedesc): ptr T {.inline.}=
  result = al.alloc(alignof(T), sizeof(T))

proc alloc_array(al: var LifoAllocator, T: typedesc, length: int): ptr UncheckedArray[T] {.inline.}=
  result = al.alloc(alignof(T), sizeof(T) * length)
