# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../config,
  ../instrumentation/contracts,
  ../memory/allocs,
  ../random/rng

template selectUint(): typedesc =
  # we keep high(uint) i;e. 0xFFFFFFFF ...
  # as a special value to signify absence in the set
  # So we have one less value to work with
  when WV_MaxWorkers <= int high(uint8):
    uint8
  elif WV_MaxWorkers <= int high(uint16):
    uint16
  else:
    uint32

type Setuint = selectUint()

const Empty = high(Setuint)

type
  SparseSet* = object
    ## Stores efficiently a set of integers in the range [0 .. Capacity)
    ## Supports:
    ## - O(1)      inclusion, exclusion and contains
    ## - O(1)      random pick
    ## - O(1)      length
    ## - O(length) iteration
    ##
    ## Space: Capacity * sizeof(words)
    ##
    ## This is contrary to bitsets which requires:
    ## - random picking: multiple random "contains" + a fallback to uncompressing the set
    ## - O(Capacity/sizeof(words)) length (via popcounts)
    ## - O(capacity) iteration
    indices: ptr UncheckedArray[Setuint]
    values: ptr UncheckedArray[Setuint]
    rawBuffer: ptr UncheckedArray[Setuint]
    len*: Setuint
    capacity*: Setuint

func allocate*(s: var SparseSet, capacity: SomeInteger) =
  preCondition: capacity <= WV_MaxWorkers

  s.capacity = Setuint capacity
  s.rawBuffer = wv_alloc(Setuint, 2*capacity)
  s.indices = s.rawBuffer
  s.values = cast[ptr UncheckedArray[Setuint]](s.rawBuffer[capacity].addr)

func delete*(s: var SparseSet) =
  s.indices = nil
  s.values = nil
  wv_free(s.rawBuffer)


func refill*(s: var SparseSet) {.inline.} =
  ## Reset the sparseset by including all integers
  ## in the range [0 .. Capacity)
  preCondition: not s.indices.isNil
  preCondition: not s.values.isNil
  preCondition: not s.rawBuffer.isNil
  preCondition: s.capacity != 0

  s.len = s.capacity

  for i in Setuint(0) ..< s.len:
    s.indices[i] = i
    s.values[i] = i

func isEmpty*(s: SparseSet): bool {.inline.} =
  s.len == 0

func contains*(s: SparseSet, n: SomeInteger): bool {.inline.} =
  assert n.int != Empty.int
  s.indices[n] != Empty

func incl*(s: var SparseSet, n: SomeInteger) {.inline.} =
  preCondition: n < Empty

  if n in s: return

  preCondition: s.len < s.capacity

  s.indices[n] = s.len
  s.values[s.len] = n
  s.len += 1

func peek*(s: SparseSet): int32 {.inline.} =
  ## Returns the last point in the set
  ## Note: if an item is deleted this is not the last inserted point
  preCondition: s.len.int > 0
  int32 s.values[s.len - 1]

func excl*(s: var SparseSet, n: SomeInteger) {.inline.} =
  if n notin s: return

  # We do constant time deletion by replacing the deleted
  # integer by the last value in the array of values

  let delIdx = s.indices[n]

  s.len -= 1
  let lastVal = s.values[s.len]

  s.indices[lastVal] = del_idx         # Last value now points to deleted index
  s.values[delIdx] = s.values[lastVal] # Deleted item is now last value

  # Erase the item
  s.indices[n] = Empty

func randomPick*(s: SparseSet, rng: var RngState): int32 =
  ## Randomly pick from the set.
  # The value is NOT removed from it.
  # TODO: this would require rejection sampling for proper uniform distribution
  # TODO: use a rng with better speed / distribution
  let pickIdx = rng.uniform(s.len)
  result = s.values[pickIdx].int32

func `$`*(s: SparseSet): string =
  $toOpenArray(s.values, 0, s.len.int - 1)

# Sanity checks
# ------------------------------------------------------------------------------

when isMainModule:

  const Size = 10
  const Picked = 5

  var S: SparseSet
  S.allocate(Size)
  S.refill()
  echo S

  var rng = 123'u32
  var picked: seq[int32]

  for _ in 0 ..< Picked:
    let p = S.randomPick(rng)
    picked.add p
    S.excl p
    echo "---"
    echo "picked: ", p
    echo "S indices: ", toOpenArray(S.indices, 0, S.capacity.int - 1)

  echo "---"
  echo "picked: ", picked
  echo "S: ", S
  echo "S indices: ", toOpenArray(S.indices, 0, S.capacity.int - 1)

  for x in 0'i32 ..< Size:
    if x notin picked:
      echo x, " notin picked -> in S"
      doAssert x in S
    else:
      echo x, " in picked -> notin S"
      doAssert x notin S
