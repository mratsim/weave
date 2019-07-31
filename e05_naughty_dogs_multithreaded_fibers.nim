# 05 - Implementation of Parallelizing the Naughty Dogs engine
#      with fibers
#      Talk: https://gdcvault.com/play/1022186/Parallelizing-the-Naughty-Dog-Engine
#      Slides: http://twvideo01.ubm-us.net/o1/vault/gdc2015/presentations/Gyrling_Christian_Parallelizing_The_Naughty.pdf
#
# Characteristics:
# - A pool of lightweight fibers are dispatch on
#   hardware threads
# - Fiber can be stopped or resumed at any point,
#   - You don't have to take the first or
#     the last in a deque as with traditional work-stealing
#   - Fiber jobs do not have to run to completion reducing latency
#     if for example a new input/event should have priority
# - For time-to-market reason, authors did not implement
#   work-stealing or private deque
#   but had 3 queues with different priorities, which may
#   trigger contention issues
