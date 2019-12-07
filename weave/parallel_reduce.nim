# Weave
# Copyright (c) 2019 Mamy André-Ratsimbazafy
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# Parallel reductions
# ----------------------------------------------------------

import
  # Standard library
  macros, typetraits,
  # Internal
  ./scheduler, ./runtime, ./contexts,
  ./datatypes/sync_types,
  ./instrumentation/[contracts, profilers]

when not compileOption("threads"):
  {.error: "This requires --threads:on compilation flag".}


