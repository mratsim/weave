/*******************************************************************************
* Copyright 2019 Intel Corporation
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*******************************************************************************/

#ifndef MKLDNN_CONFIG_H
#define MKLDNN_CONFIG_H

#ifndef DOXYGEN_SHOULD_SKIP_THIS

// All symbols shall be internal unless marked as MKLDNN_API
#if defined _WIN32 || defined __CYGWIN__
#   define MKLDNN_HELPER_DLL_IMPORT __declspec(dllimport)
#   define MKLDNN_HELPER_DLL_EXPORT __declspec(dllexport)
#else
#   if __GNUC__ >= 4
#       define MKLDNN_HELPER_DLL_IMPORT __attribute__((visibility("default")))
#       define MKLDNN_HELPER_DLL_EXPORT __attribute__((visibility("default")))
#   else
#       define MKLDNN_HELPER_DLL_IMPORT
#       define MKLDNN_HELPER_DLL_EXPORT
#   endif
#endif

#ifdef MKLDNN_DLL
#   ifdef MKLDNN_DLL_EXPORTS
#       define MKLDNN_API MKLDNN_HELPER_DLL_EXPORT
#   else
#       define MKLDNN_API MKLDNN_HELPER_DLL_IMPORT
#   endif
#else
#   define MKLDNN_API
#endif

#if defined (__GNUC__)
#   define MKLDNN_DEPRECATED __attribute__((deprecated))
#elif defined(_MSC_VER)
#   define MKLDNN_DEPRECATED __declspec(deprecated)
#else
#   define MKLDNN_DEPRECATED
#endif
#endif // DOXYGEN_SHOULD_SKIP_THIS

// No runtime (disabled)
#define MKLDNN_RUNTIME_NONE 0u
// Sequential runtime (CPU only)
#define MKLDNN_RUNTIME_SEQ 1u
// OpenMP runtime (CPU only)
#define MKLDNN_RUNTIME_OMP 2u
// TBB runtime (CPU only)
#define MKLDNN_RUNTIME_TBB 4u
// OpenCL runtime
#define MKLDNN_RUNTIME_OCL 256u

// MKL-DNN CPU engine runtime
#define MKLDNN_CPU_RUNTIME MKLDNN_RUNTIME_OMP

// MKL-DNN GPU engine runtime
#define MKLDNN_GPU_RUNTIME MKLDNN_RUNTIME_NONE

#if defined(MKLDNN_CPU_RUNTIME) && defined(MKLDNN_GPU_RUNTIME)
#    if (MKLDNN_CPU_RUNTIME == MKLDNN_RUNTIME_NONE) \
            || (MKLDNN_CPU_RUNTIME == MKLDNN_RUNTIME_OCL)
#        error "Unexpected MKLDNN_CPU_RUNTIME"
#    endif
#    if (MKLDNN_GPU_RUNTIME != MKLDNN_RUNTIME_NONE) \
            && (MKLDNN_GPU_RUNTIME != MKLDNN_RUNTIME_OCL)
#        error "Unexpected MKLDNN_GPU_RUNTIME"
#    endif
#else
#    error "BOTH MKLDNN_CPU_RUNTIME and MKLDNN_GPU_RUNTIME must be defined"
#endif

#endif
