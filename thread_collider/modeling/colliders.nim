# Thread Collider
# Copyright (c) 2020 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  ../[shadow, collider_common]

# Collider
# ----------------------------------------------------------------------------------
#
# Note: those types are held in a global with the lifetime of the whole programs
#       and should never be collected, in particular on fiber context switch

type
  Collider* = object
    ## The Global Collider context
    dag: DAG
    scheduler: Scheduler

  Scheduler = object
    threadpool: seq[ShadowThread]


  ExecutionContext = object
    
