# Original cpuinfo.h header
# Copyright (c) 2017-2018 Facebook Inc.
# Copyright (C) 2012-2017 Georgia Institute of Technology
# Copyright (C) 2010-2012 Marat Dukhan
#
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# * Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
#
# * Redistributions in binary form must reproduce the above copyright notice,
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Nim wrapper - Laser
# Copyright (c) 2018 Mamy André-Ratsimbazafy
# Distributed under the Apache v2 License (license terms are at http://www.apache.org/licenses/LICENSE-2.0).
# This file may not be copied, modified, or distributed except according to those terms.

from strutils import split, rsplit
from os import DirSep

const
  curSrcFolder = currentSourcePath.rsplit(DirSep, 1)[0]
  cpuinfoPath = curSrcFolder & DirSep & "cpuinfo" & DirSep
  # We use a patched header as the original one doesn't typedef its struct
  # which lead to "error: must use 'struct' tag to refer to type 'cpuinfo_processor'"
  # headerPath = cpuinfoPath & DirSep & "include" & DirSep & "cpuinfo.h"
  headerPath = curSrcFolder & DirSep & "cpuinfo.h"

###########################################
############### Public API ################

{.pragma:cpuinfo_type, header: headerPath, bycopy.}

# Check compiler defined consts in:
#   - https://github.com/nim-lang/Nim/blob/devel/compiler/platform.nim

type
  CPUInfo_cache* {.importc: "cpuinfo_cache_exported", cpuinfo_type.} = object
    size* {.importc.}: uint32
    associativity* {.importc.}: uint32
    sets* {.importc.}: uint32
    partitions* {.importc.}: uint32
    line_size* {.importc.}: uint32
    flags* {.importc.}: uint32
    processor_start* {.importc.}: uint32
    processor_count* {.importc.}: uint32

  ProcCache* {.bycopy.} = object
    l1i*: ptr CPUInfo_cache
    l1d*: ptr CPUInfo_cache
    l2*: ptr CPUInfo_cache
    l3*: ptr CPUInfo_cache
    l4*: ptr CPUInfo_cache

  CPUInfo_processor* {.importc: "cpuinfo_processor_exported", cpuinfo_type.} = object
    smt_id* {.importc.}: uint32
    core* {.importc.}: ptr CPUInfo_core
    cluster* {.importc.}: ptr CPUInfo_cluster
    package* {.importc.}: ptr CPUInfo_package
    cache* {.importc.}: ptr ProcCache

  CPUInfo_core* {.importc: "cpuinfo_core_exported", cpuinfo_type.} = object
    processor_start* {.importc.}: uint32
    processor_count* {.importc.}: uint32
    core_id* {.importc.}: uint32
    cluster* {.importc.}: ptr CPUInfo_cluster
    package* {.importc.}: ptr CPUInfo_package
    vendor* {.importc.}: CPUInfo_vendor
    uarch* {.importc.}: CPUInfo_uarch
    when defined(i386) or defined(amd64):
      cpuid* {.importc.}: uint32
    when defined(arm) or defined(arm64):
      midr* {.importc.}: uint32
    frequency* {.importc.}: uint64

  CPUInfo_cluster* {.importc: "cpuinfo_cluster_exported", cpuinfo_type.} = object
    processor_start* {.importc.}: uint32
    processor_count* {.importc.}: uint32
    core_start* {.importc.}: uint32
    core_count* {.importc.}: uint32
    cluster_id* {.importc.}: uint32
    package* {.importc.}: ptr CPUInfo_package
    vendor* {.importc.}: CPUInfo_vendor
    uarch* {.importc.}: CPUInfo_uarch
    when defined(i386) or defined(amd64):
      cpuid* {.importc.}: uint32
    when defined(arm) or defined(arm64):
      midr* {.importc.}: uint32
    frequency* {.importc.}: uint64

  CPUInfo_package* {.importc: "cpuinfo_package_exported", cpuinfo_type.} = object
    name* {.importc.}: array[48, char]
    when defined(android) or defined(ios):
      # Make sure iOS is defined - https://github.com/nim-lang/Nim/issues/9369
      gpu_name* {.importc.}: array[64, char]
    processor_start* {.importc.}: uint32
    processor_count* {.importc.}: uint32
    core_start* {.importc.}: uint32
    core_count* {.importc.}: uint32
    cluster_start* {.importc.}: uint32
    cluster_count* {.importc.}: uint32

  CPUInfo_vendor* {.size: sizeof(cint).} = enum
    ## * Processor vendor is not known to the library, or the library failed to get vendor information from the OS.
    cpuinfo_vendor_unknown = 0,
    ##  Active vendors of modern CPUs
    cpuinfo_vendor_intel = 1,
    cpuinfo_vendor_amd = 2,
    cpuinfo_vendor_arm = 3,
    cpuinfo_vendor_qualcomm = 4,
    cpuinfo_vendor_apple = 5,
    cpuinfo_vendor_samsung = 6,
    cpuinfo_vendor_nvidia = 7,
    cpuinfo_vendor_mips = 8,
    cpuinfo_vendor_ibm = 9,
    cpuinfo_vendor_ingenic = 10,
    cpuinfo_vendor_via = 11,
    cpuinfo_vendor_cavium = 12,
    cpuinfo_vendor_broadcom = 13,
    cpuinfo_vendor_apm = 14, # Applied Micro Circuits Corporation (APM)
    cpuinfo_vendor_huawei = 15,
    cpuinfo_vendor_texas_instruments = 30,
    cpuinfo_vendor_marvell = 31,
    cpuinfo_vendor_rdc = 32, # RDC Semiconductor Co.
    cpuinfo_vendor_dmp = 33, # DM&P Electronics Inc.
    cpuinfo_vendor_motorola = 34,
    cpuinfo_vendor_transmeta = 50,
    cpuinfo_vendor_cyrix = 51,
    cpuinfo_vendor_rise = 52,
    cpuinfo_vendor_nsc = 53, # National Semiconductor
    cpuinfo_vendor_sis = 54, # Silicon Integrated Systems
    cpuinfo_vendor_nexgen = 55,
    cpuinfo_vendor_umc = 56, # United Microelectronics Corporation
    cpuinfo_vendor_dec = 57 # Digital Equipment Corporation

  CPUInfo_uarch* {.size: sizeof(cint).} = enum
    cpuinfo_uarch_unknown = 0, ## Microarchitecture is unknown, or the library failed to get information about the microarchitecture from OS
    cpuinfo_uarch_p5 = 0x00100100, ## Pentium and Pentium MMX microarchitecture.
    cpuinfo_uarch_quark = 0x00100101, ## Intel Quark microarchitecture.
    cpuinfo_uarch_p6 = 0x00100200, ## Pentium Pro, Pentium II, and Pentium III.
    cpuinfo_uarch_dothan = 0x00100201, ## Pentium M.
    cpuinfo_uarch_yonah = 0x00100202, ## Intel Core microarchitecture.
    cpuinfo_uarch_conroe = 0x00100203, ## Intel Core 2 microarchitecture on 65 nm process.
    cpuinfo_uarch_penryn = 0x00100204, ## Intel Core 2 microarchitecture on 45 nm process.
    cpuinfo_uarch_nehalem = 0x00100205, ## Intel Nehalem and Westmere microarchitectures (Core i3/i5/i7 1st gen).
    cpuinfo_uarch_sandy_bridge = 0x00100206, ## Intel Sandy Bridge microarchitecture (Core i3/i5/i7 2nd gen).
    cpuinfo_uarch_ivy_bridge = 0x00100207, ## Intel Ivy Bridge microarchitecture (Core i3/i5/i7 3rd gen).
    cpuinfo_uarch_haswell = 0x00100208, ## Intel Haswell microarchitecture (Core i3/i5/i7 4th gen).
    cpuinfo_uarch_broadwell = 0x00100209, ## Intel Broadwell microarchitecture.
    cpuinfo_uarch_sky_lake = 0x0010020A, ## Intel Sky Lake microarchitecture.
    cpuinfo_uarch_kaby_lake = 0x0010020B, ## Intel Kaby Lake microarchitecture.
    cpuinfo_uarch_willamette = 0x00100300, ## Pentium 4 with Willamette, Northwood, or Foster cores.
    cpuinfo_uarch_prescott = 0x00100301, ## Pentium 4 with Prescott and later cores.
    cpuinfo_uarch_bonnell = 0x00100400, ## Intel Atom on 45 nm process.
    cpuinfo_uarch_saltwell = 0x00100401, ## Intel Atom on 32 nm process.
    cpuinfo_uarch_silvermont = 0x00100402, ## Intel Silvermont microarchitecture (22 nm out-of-order Atom).
    cpuinfo_uarch_airmont = 0x00100403, ## Intel Airmont microarchitecture (14 nm out-of-order Atom).
    cpuinfo_uarch_knights_ferry = 0x00100500, ## Intel Knights Ferry HPC boards.
    cpuinfo_uarch_knights_corner = 0x00100501, ## Intel Knights Corner HPC boards (aka Xeon Phi).
    cpuinfo_uarch_knights_landing = 0x00100502, ## Intel Knights Landing microarchitecture (second-gen MIC).
    cpuinfo_uarch_knights_hill = 0x00100503, ## Intel Knights Hill microarchitecture (third-gen MIC).
    cpuinfo_uarch_knights_mill = 0x00100504, ## Intel Knights Mill Xeon Phi.
    cpuinfo_uarch_xscale = 0x00100600, ## Intel/Marvell XScale series.
    cpuinfo_uarch_k5 = 0x00200100, ## AMD K5.
    cpuinfo_uarch_k6 = 0x00200101, ## AMD K6 and alike.
    cpuinfo_uarch_k7 = 0x00200102, ## AMD Athlon and Duron.
    cpuinfo_uarch_k8 = 0x00200103, ## AMD Athlon 64, Opteron 64.
    cpuinfo_uarch_k10 = 0x00200104, ## AMD Family 10h (Barcelona, Istambul, Magny-Cours).
    cpuinfo_uarch_bulldozer = 0x00200105, ## AMD Bulldozer microarchitecture. Zambezi FX-series CPUs, Zurich, Valencia and Interlagos Opteron CPUs.
    cpuinfo_uarch_piledriver = 0x00200106, ## AMD Piledriver microarchitecture. Vishera FX-series CPUs, Trinity and Richland APUs, Delhi, Seoul, Abu Dhabi Opteron CPUs.
    cpuinfo_uarch_steamroller = 0x00200107, ## AMD Steamroller microarchitecture (Kaveri APUs).
    cpuinfo_uarch_excavator = 0x00200108, ## AMD Excavator microarchitecture (Carizzo APUs).
    cpuinfo_uarch_zen = 0x00200109, ## AMD Zen microarchitecture (Ryzen CPUs).
    cpuinfo_uarch_geode = 0x00200200, ## NSC Geode and AMD Geode GX and LX.
    cpuinfo_uarch_bobcat = 0x00200201, ## AMD Bobcat mobile microarchitecture.
    cpuinfo_uarch_jaguar = 0x00200202, ## AMD Jaguar mobile microarchitecture.
    cpuinfo_uarch_puma = 0x00200203, ## AMD Puma mobile microarchitecture.
    cpuinfo_uarch_arm7 = 0x00300100, ## ARM7 series.
    cpuinfo_uarch_arm9 = 0x00300101, ## ARM9 series.
    cpuinfo_uarch_arm11 = 0x00300102, ## ARM 1136, ARM 1156, ARM 1176, or ARM 11MPCore.
    cpuinfo_uarch_cortex_a5 = 0x00300205, ## ARM Cortex-A5.
    cpuinfo_uarch_cortex_a7 = 0x00300207, ## ARM Cortex-A7.
    cpuinfo_uarch_cortex_a8 = 0x00300208, ## ARM Cortex-A8.
    cpuinfo_uarch_cortex_a9 = 0x00300209, ## ARM Cortex-A9.
    cpuinfo_uarch_cortex_a12 = 0x00300212, ## ARM Cortex-A12.
    cpuinfo_uarch_cortex_a15 = 0x00300215, ## ARM Cortex-A15.
    cpuinfo_uarch_cortex_a17 = 0x00300217, ## ARM Cortex-A17.
    cpuinfo_uarch_cortex_a32 = 0x00300332, ## ARM Cortex-A32.
    cpuinfo_uarch_cortex_a35 = 0x00300335, ## ARM Cortex-A35.
    cpuinfo_uarch_cortex_a53 = 0x00300353, ## ARM Cortex-A53.
    cpuinfo_uarch_cortex_a55 = 0x00300355, ## ARM Cortex-A55.
    cpuinfo_uarch_cortex_a57 = 0x00300357, ## ARM Cortex-A57.
    cpuinfo_uarch_cortex_a72 = 0x00300372, ## ARM Cortex-A72.
    cpuinfo_uarch_cortex_a73 = 0x00300373, ## ARM Cortex-A73.
    cpuinfo_uarch_cortex_a75 = 0x00300375, ## ARM Cortex-A75.
    cpuinfo_uarch_cortex_a76 = 0x00300376, ## ARM Cortex-A76.
    cpuinfo_uarch_scorpion = 0x00400100, ## Qualcomm Scorpion.
    cpuinfo_uarch_krait = 0x00400101, ## Qualcomm Krait.
    cpuinfo_uarch_kryo = 0x00400102, ## Qualcomm Kryo.
    cpuinfo_uarch_falkor = 0x00400103, ## Qualcomm Falkor.
    cpuinfo_uarch_saphira = 0x00400104, ## Qualcomm Saphira.
    cpuinfo_uarch_denver = 0x00500100, ## Nvidia Denver.
    cpuinfo_uarch_denver2 = 0x00500101, ## Nvidia Denver 2.
    cpuinfo_uarch_carmel = 0x00500102, ## Nvidia Carmel.
    cpuinfo_uarch_mongoose_m1 = 0x00600100, ## Samsung Mongoose M1 (Exynos 8890 big cores).
    cpuinfo_uarch_mongoose_m2 = 0x00600101, ## Samsung Mongoose M2 (Exynos 8895 big cores).
    cpuinfo_uarch_meerkat_m3 = 0x00600102, ## Samsung Meerkat M3 (Exynos 9810 big cores).
    cpuinfo_uarch_swift = 0x00700100, ## Apple A6 and A6X processors.
    cpuinfo_uarch_cyclone = 0x00700101, ## Apple A7 processor.
    cpuinfo_uarch_typhoon = 0x00700102, ## Apple A8 and A8X processor.
    cpuinfo_uarch_twister = 0x00700103, ## Apple A9 and A9X processor.
    cpuinfo_uarch_hurricane = 0x00700104, ## Apple A10 and A10X processor.
    cpuinfo_uarch_monsoon = 0x00700105, ## Apple A11 processor (big cores).
    cpuinfo_uarch_mistral = 0x00700106, ## Apple A11 processor (little cores).
    cpuinfo_uarch_thunderx = 0x00800100, ## Cavium ThunderX.
    cpuinfo_uarch_thunderx2 = 0x00800200, ## Cavium ThunderX2 (originally Broadcom Vulkan).
    cpuinfo_uarch_pj4 = 0x00900100, ## Marvell PJ4.
    cpuinfo_uarch_brahma_b15 = 0x00A00100, ## Broadcom Brahma B15.
    cpuinfo_uarch_brahma_b53 = 0x00A00101, ## Broadcom Brahma B53.
    cpuinfo_uarch_xgene = 0x00B00100 ## Applied Micro X-Gene.

{.pragma: cpuinfo_proc, importc, header: headerPath, cdecl.}

proc cpuinfo_initialize(): bool {.cpuinfo_proc.}
proc cpuinfo_deinitialize() {.cpuinfo_proc, noconv.} # noconv for addQuitProc

proc cpuinfo_get_processors*(): ptr CPUInfo_processor {.cpuinfo_proc.}
proc cpuinfo_get_cores*(): ptr CPUInfo_core {.cpuinfo_proc.}
proc cpuinfo_get_clusters*(): ptr CPUInfo_cluster {.cpuinfo_proc.}
proc cpuinfo_get_packages*(): ptr CPUInfo_package {.cpuinfo_proc.}
proc cpuinfo_get_l1i_caches*(): ptr CPUInfo_cache {.cpuinfo_proc.}
proc cpuinfo_get_l1d_caches*(): ptr CPUInfo_cache {.cpuinfo_proc.}
proc cpuinfo_get_l2_caches*(): ptr CPUInfo_cache {.cpuinfo_proc.}
proc cpuinfo_get_l3_caches*(): ptr CPUInfo_cache {.cpuinfo_proc.}
proc cpuinfo_get_l4_caches*(): ptr CPUInfo_cache {.cpuinfo_proc.}
proc cpuinfo_get_processor*(index: uint32): ptr CPUInfo_processor {.cpuinfo_proc.}
proc cpuinfo_get_core*(index: uint32): ptr CPUInfo_core {.cpuinfo_proc.}
proc cpuinfo_get_cluster*(index: uint32): ptr CPUInfo_cluster {.cpuinfo_proc.}
proc cpuinfo_get_package*(index: uint32): ptr CPUInfo_package {.cpuinfo_proc.}
proc cpuinfo_get_l1i_cache*(index: uint32): ptr CPUInfo_cache {.cpuinfo_proc.}
proc cpuinfo_get_l1d_cache*(index: uint32): ptr CPUInfo_cache {.cpuinfo_proc.}
proc cpuinfo_get_l2_cache*(index: uint32): ptr CPUInfo_cache {.cpuinfo_proc.}
proc cpuinfo_get_l3_cache*(index: uint32): ptr CPUInfo_cache {.cpuinfo_proc.}
proc cpuinfo_get_l4_cache*(index: uint32): ptr CPUInfo_cache {.cpuinfo_proc.}
proc cpuinfo_get_processors_count*(): uint32 {.cpuinfo_proc.}
proc cpuinfo_get_cores_count*(): uint32 {.cpuinfo_proc.}
proc cpuinfo_get_clusters_count*(): uint32 {.cpuinfo_proc.}
proc cpuinfo_get_packages_count*(): uint32 {.cpuinfo_proc.}
proc cpuinfo_get_l1i_caches_count*(): uint32 {.cpuinfo_proc.}
proc cpuinfo_get_l1d_caches_count*(): uint32 {.cpuinfo_proc.}
proc cpuinfo_get_l2_caches_count*(): uint32 {.cpuinfo_proc.}
proc cpuinfo_get_l3_caches_count*(): uint32 {.cpuinfo_proc.}
proc cpuinfo_get_l4_caches_count*(): uint32 {.cpuinfo_proc.}
proc cpuinfo_get_current_processor*(): ptr CPUInfo_processor {.cpuinfo_proc.}
proc cpuinfo_get_current_core*(): ptr CPUInfo_core {.cpuinfo_proc.}

###########################################
################# C files #################

# clog dependency
{.passC: "-I" & cpuinfoPath & "deps/clog/include".}
{.compile: cpuinfoPath & "deps/clog/src/clog.c".}

# Headers - use the patched header with typedefs
# Also for some reason we need to passC in the same line
# Otherwise "curSrcFolder" is ignored
{.passC: "-I" & cpuinfoPath & "src -I" & curSrcFolder.}

when defined(linux):
  {.passC: "-D_GNU_SOURCE".}
  {.passL: "-lpthread".}

template compile(path: static string): untyped =
  # Path: the path from cpuinfo/src folder
  const compiled_object = block:
    var obj_name = "cpuinfo"
    for subPath in path.split(DirSep):
      obj_name &= "_" & subPath
    obj_name &= ".o"
    obj_name
  # we need to use relative paths https://github.com/nim-lang/Nim/issues/9370
  {.compile:("./cpuinfo/src/" & path, compiled_object).}

when defined(arm) or defined(arm64):
  when defined(android):
    compile"arm/android/gpu.c"
    compile"arm/android/properties.c"
  elif defined(linux):
    compile"arm/linux/aarch32-isa.c"
    compile"arm/linux/aarch64-isa.c"
    compile"arm/linux/chipset.c"
    compile"arm/linux/clusters.c"
    compile"arm/linux/cpuinfo.c"
    compile"arm/linux/hwcap.c"
    compile"arm/linux/init.c"
    compile"arm/linux/midr.c"
  elif defined(iOS): # we don't support GNU Hurd ¯\_(ツ)_/¯
    compile"arm/mach/init.c"
    # iOS GPU
    # compile"gpu/gles-ios.m" # TODO: Obj-C compilation
  compile"arm/cache.c"
  compile"arm/tlb.c"
  compile"arm/uarch.c"
  # ARM GPU
  compile"gpu/gles2.c"

when defined(linux):
  compile"linux/cpulist.c"
  compile"linux/current.c"
  compile"linux/gpu.c"
  compile"linux/multiline.c"
  compile"linux/processors.c"
  compile"linux/smallfile.c"

when defined(iOS) or defined(macos) or defined(macosx): # # we don't support GNU Hurd ¯\_(ツ)_/¯
  compile"mach/topology.c"

when defined(i386) or defined(amd64):
  compile"x86/cache/descriptor.c"
  compile"x86/cache/deterministic.c"
  compile"x86/cache/init.c"
  when defined(linux):
    compile"x86/linux/cpuinfo.c"
    compile"x86/linux/init.c"
  elif defined(iOS) or defined(macos) or defined(macosx):
    compile"x86/mach/init.c"
  # compile"src/x86/nacl/isa.c" # TODO: NaCl support
  compile"x86/info.c"
  compile"x86/init.c"
  compile"x86/isa.c"
  compile"x86/name.c"
  compile"x86/topology.c"
  compile"x86/uarch.c"
  compile"x86/vendor.c"

compile"api.c"
compile"init.c"

###########################################
################# Runtime #################

if not cpuinfo_initialize():
  raise newException(LibraryError, "Could not initialize the cpuinfo module")
addQuitProc(cpuinfo_deinitialize)

{.pragma: cpuinfo, cdecl, header: headerPath.}
func cpuinfo_has_x86_sse*(): bool {.cpuinfo.}
func cpuinfo_has_x86_sse2*(): bool {.cpuinfo.}
func cpuinfo_has_x86_sse3*(): bool {.cpuinfo.}
func cpuinfo_has_x86_sse4_1*(): bool {.cpuinfo.}
func cpuinfo_has_x86_avx*(): bool {.cpuinfo.}
func cpuinfo_has_x86_avx2*(): bool {.cpuinfo.}
func cpuinfo_has_x86_avx512f*(): bool {.cpuinfo.}

func cpuinfo_has_x86_fma3*(): bool {.cpuinfo.}
