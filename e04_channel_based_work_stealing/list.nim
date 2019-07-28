# Intrusive linked list data structure
# ----------------------------------------------------------------------------------

type
  IntrusiveListNode* = object
    next*, prev*: ptr IntrusiveListNode
