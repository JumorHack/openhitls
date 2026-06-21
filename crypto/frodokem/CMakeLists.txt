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


file(GLOB _frodokem_sources ${CMAKE_CURRENT_SOURCE_DIR}/src/*.c)

set(_frodokem_sources
    ${CMAKE_CURRENT_SOURCE_DIR}/src/frodokem.c
    ${CMAKE_CURRENT_SOURCE_DIR}/src/frodo_util.c
    ${CMAKE_CURRENT_SOURCE_DIR}/src/frodo_params.c
    ${CMAKE_CURRENT_SOURCE_DIR}/src/frodokem_pke.c
    ${CMAKE_CURRENT_SOURCE_DIR}/src/frodo_core_ref.c
)

if(HITLS_CRYPTO_FRODOKEM_ARMV8)
    list(APPEND _frodokem_sources
        ${CMAKE_CURRENT_SOURCE_DIR}/src/asm/armv8_frodo_matmul.S
        ${CMAKE_CURRENT_SOURCE_DIR}/src/asm/armv8_frodo_sample.S
    )
endif()

add_library(_hitls_crypto_frodokem OBJECT ${_frodokem_sources})

# Ablation switches (TCHES paper §4.x).  Configure-time options that
# propagate as compile definitions to the FrodoKEM TU exclusively, so the
# rest of the library stays unaffected.  Driven from CMake -D flags, NOT
# from CMAKE_C_FLAGS, to avoid ordering issues with global -D flags.
option(FRODO_NAIVE_SCHEDULE  "Use row-at-a-time MLA schedule for MultAsPlusEAES, config E (ablation)" OFF)
option(FRODO_RR_SCHEDULE     "Use round-robin MLA schedule for MultAsPlusEAES, config B (ablation)" OFF)
option(DISABLE_NEON_SAMPLE   "Force scalar C sampler even when NEON is on (ablation)" OFF)
# BENCHMARK-ONLY (paper experiment E2): skip the multiply-accumulate in the
# matrix routines so they time Gen(A) alone.  Produces INCORRECT KEM output;
# never enable in a production build.  MAC time = Total - Gen.
option(FRODO_BENCH_GEN_ONLY  "Skip MAC, measure on-the-fly A generation only (E2 decomposition)" OFF)

if(FRODO_NAIVE_SCHEDULE AND FRODO_RR_SCHEDULE)
    message(FATAL_ERROR "Enable at most one of FRODO_NAIVE_SCHEDULE and FRODO_RR_SCHEDULE")
endif()
if(FRODO_NAIVE_SCHEDULE)
    target_compile_definitions(_hitls_crypto_frodokem PRIVATE FRODO_NAIVE_SCHEDULE)
    message(STATUS "FrodoKEM ablation: row-at-a-time schedule selected (config E, MultAsPlusEAES_naive)")
endif()
if(FRODO_RR_SCHEDULE)
    target_compile_definitions(_hitls_crypto_frodokem PRIVATE FRODO_RR_SCHEDULE)
    message(STATUS "FrodoKEM ablation: round-robin schedule selected (config B, MultAsPlusEAES_rr)")
endif()
if(DISABLE_NEON_SAMPLE)
    target_compile_definitions(_hitls_crypto_frodokem PRIVATE DISABLE_NEON_SAMPLE)
    message(STATUS "FrodoKEM ablation: scalar sampler selected (DISABLE_NEON_SAMPLE)")
endif()
if(FRODO_BENCH_GEN_ONLY)
    target_compile_definitions(_hitls_crypto_frodokem PRIVATE FRODO_BENCH_GEN_ONLY)
    message(WARNING "FrodoKEM E2: GEN-ONLY build (MAC skipped) -- benchmark only, KEM output is INVALID")
endif()

target_link_libraries(_hitls_crypto_frodokem
    PUBLIC
        _hitls_crypto_common_include
)

target_include_directories(_hitls_crypto_frodokem
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${PROJECT_SOURCE_DIR}/crypto/eal/src
)

hitls_register_objects(CRYPTO _hitls_crypto_frodokem)
