# This file is part of the openHiTLS project.
#
# openHiTLS is licensed under the Mulan PSL v2.
# You can use this software according to the terms and conditions of the Mulan PSL v2.
# You may obtain a copy of Mulan PSL v2 at:
#
#     http://license.coscl.org.cn/MulanPSL2
#
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
# EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
# MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
# See the Mulan PSL v2 for more details.

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    project(openHiTLS_BENCHMARK LANGUAGES C)
    message(FATAL_ERROR
        "Build openHiTLS benchmark from the root build with -DHITLS_BUILD_BENCHMARK=ON.")
endif()

foreach(_req
    HITLS_BSL
    HITLS_CRYPTO
    HITLS_CRYPTO_EAL
    HITLS_CRYPTO_DRBG
    HITLS_CRYPTO_DRBG_HASH
    HITLS_CRYPTO_ENTROPY)
    if(NOT ${_req})
        message(FATAL_ERROR
            "openHiTLS benchmark requires ${_req}=ON in the current build profile.")
    endif()
endforeach()

set(_benchmark_bsl_target "")
if(TARGET hitls_bsl-static)
    set(_benchmark_bsl_target hitls_bsl-static)
elseif(TARGET hitls_bsl-shared)
    set(_benchmark_bsl_target hitls_bsl-shared)
else()
    message(FATAL_ERROR "openHiTLS benchmark requires hitls_bsl-static or hitls_bsl-shared.")
endif()

set(_benchmark_crypto_target "")
if(TARGET hitls_crypto-static)
    set(_benchmark_crypto_target hitls_crypto-static)
elseif(TARGET hitls_crypto-shared)
    set(_benchmark_crypto_target hitls_crypto-shared)
else()
    message(FATAL_ERROR "openHiTLS benchmark requires hitls_crypto-static or hitls_crypto-shared.")
endif()

set(_benchmark_link_libs
    ${_benchmark_crypto_target}
    ${_benchmark_bsl_target})

if(HITLS_BSL_SAL_DL AND (HITLS_BSL_SAL_LINUX OR HITLS_BSL_SAL_DARWIN))
    list(APPEND _benchmark_link_libs dl)
endif()
if(UNIX AND NOT APPLE)
    list(APPEND _benchmark_link_libs pthread)
endif()
if(_G_HITLS_APPROVED_PROVIDER)
    list(APPEND _benchmark_link_libs m)
endif()

file(GLOB BENCHS "*_bench.c")

add_compile_options(-g)
# -z noexecstack: Mark the stack as non-executable (ELF security feature)
# Supported by: GNU ld (all versions), LLVM lld 7.0+
# Not needed on: macOS (ld64 defaults to non-executable stack), Windows (uses /NXCOMPAT)
if(UNIX AND NOT APPLE)
    add_link_options(-z noexecstack)
endif()

add_executable(openhitls_benchmark benchmark.c ${BENCHS})
target_include_directories(openhitls_benchmark PRIVATE
    ${PROJECT_SOURCE_DIR}/include/crypto
    ${PROJECT_SOURCE_DIR}/include/bsl
    ${PROJECT_SOURCE_DIR}/bsl/include
    ${PROJECT_SOURCE_DIR}/crypto/include
    ${PROJECT_SOURCE_DIR}/config/macro_config)
target_link_libraries(openhitls_benchmark PRIVATE ${_benchmark_link_libs})

# ------------------------------------------------------------------
# Sub-function micro benchmark for FrodoKEM (paper Section 6 data 2).
# Built only when FrodoKEM is enabled.
# Links the internal (non-public) symbols from libhitls_crypto.
# ------------------------------------------------------------------
if(HITLS_CRYPTO_FRODOKEM)
    add_executable(frodokem_micro frodokem_micro.c)
    target_include_directories(frodokem_micro PRIVATE
        ${PROJECT_SOURCE_DIR}/include/crypto
        ${PROJECT_SOURCE_DIR}/include/bsl
        ${PROJECT_SOURCE_DIR}/bsl/include
        ${PROJECT_SOURCE_DIR}/crypto/include
        ${PROJECT_SOURCE_DIR}/crypto/frodokem/src
        ${PROJECT_SOURCE_DIR}/config/macro_config)
    # sqrtl() lives in libm
    target_link_libraries(frodokem_micro PRIVATE ${_benchmark_link_libs} m)
    if(HITLS_CRYPTO_FRODOKEM_ARMV8)
        target_compile_definitions(frodokem_micro PRIVATE HITLS_CRYPTO_FRODOKEM_ARMV8=1)
    endif()
    # Mirror the FrodoKEM library's ablation switches into the micro binary so
    # the "Schedule:" / "Sampler:" diagnostic prints reflect reality.
    if(FRODO_NAIVE_SCHEDULE)
        target_compile_definitions(frodokem_micro PRIVATE FRODO_NAIVE_SCHEDULE=1)
    endif()
    if(FRODO_RR_SCHEDULE)
        target_compile_definitions(frodokem_micro PRIVATE FRODO_RR_SCHEDULE=1)
    endif()
    if(FRODO_BENCH_GEN_ONLY)
        target_compile_definitions(frodokem_micro PRIVATE FRODO_BENCH_GEN_ONLY=1)
    endif()
    if(DISABLE_NEON_SAMPLE)
        target_compile_definitions(frodokem_micro PRIVATE DISABLE_NEON_SAMPLE=1)
    endif()

    # ------------------------------------------------------------------
    # FrodoKEM functional self-test (public EAL API only).  Verifies
    # KeyGen/Encaps/Decaps round-trips on the NEON-enabled library without
    # depending on the SDV test harness.
    # ------------------------------------------------------------------
    add_executable(frodokem_selftest frodokem_selftest.c)
    target_include_directories(frodokem_selftest PRIVATE
        ${PROJECT_SOURCE_DIR}/include/crypto
        ${PROJECT_SOURCE_DIR}/include/bsl
        ${PROJECT_SOURCE_DIR}/bsl/include
        ${PROJECT_SOURCE_DIR}/crypto/include
        ${PROJECT_SOURCE_DIR}/config/macro_config)
    target_link_libraries(frodokem_selftest PRIVATE ${_benchmark_link_libs})
endif()
