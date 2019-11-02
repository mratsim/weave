# Project Picasso
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

type
  IntrusiveStackable* = concept x, type T
    x is ptr
    x.next is T

  IntrusiveStack*[T: IntrusiveStackable] = object
    ## Generic intrusive stack for pointer objects
    ## Those objects should implement a "next" field
    ## that will be used for ordering by the IntrusiveStack
    ##
    ## IntrusiveStack takes ownership of the pointer object pushed into it.
    ## It expects elements to be allocated via createShared (i.e. shared-memory, not thread-local)
    top: T

func isEmpty*(stack: IntrusiveStack): bool {.inline.} =
  return stack.top.isNil

func add*[T](stack: var IntrusiveStack[T], elem: sink T) {.inline.} =
  assert not elem.isNil

  elem.next = stack.top
  stack.top = elem

func pop*[T](stack: var IntrusiveStack[T]): T {.inline.} =
  if stack.isEmpty:
    return nil

  result = stack.top
  stack.top = stack.top.next
  result.next = nil

proc `=destroy`*[T](stack: var IntrusiveStack[T]) =
  while (let elem = stack.pop(); not elem.isNil):
    deallocShared(elem)

# Sanity checks
# ------------------------------------------------------------------------------
# IntrusiveStacks are also tested in prell_deques.nim

when isMainModule:
  type
    Node = ptr NodeObj
    NodeObj = object
      payload: int
      next: Node

  let
    a = createShared(NodeObj)
    b = createShared(NodeObj)
    c = createShared(NodeObj)
    d = createShared(NodeObj)

  a.payload = 10
  b.payload = 20
  c.payload = 30
  d.payload = 40

  var x: IntrusiveStack[Node]
  x.add a
  x.add b
  x.add c
  x.add d

  echo x.repr
