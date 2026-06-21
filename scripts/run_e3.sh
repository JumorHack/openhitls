#!/usr/bin/env bash
#
# Experiment E3: end-to-end KEM performance at -O3.
#
# The paper's main end-to-end table (Table 2) is at -O2 (openHiTLS default).
# A reviewer asks for -O3 numbers too, since at -O3 the C reference's matrix
# loops get auto-vectorised and the matrix-kernel gap shrinks to ~1.01x.
# This measures the WHOLE KEM (KeyGen/Encaps/Decaps) at -O3 for both the C
# reference and the NEON build, across all six parameter sets.
#
# -O3 override: openHiTLS injects "-O2 -D_FORTIFY_SOURCE=2" via
# add_compile_options() AFTER CMAKE_C_FLAGS, so we strip them with
# _HITLS_COMPILE_OPTIONS_DEL and then supply -O3 ourselves
# (same mechanism as scripts/run_optlevel.sh).
#
# Usage:  bash scripts/run_e3.sh           # build + run
#         bash scripts/run_e3.sh build
#         bash scripts/run_e3.sh run
# Env:    ITERS (default 1000)

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ITERS=${ITERS:-1000}
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
ARCH_FLAGS="-march=armv8.4-a+crypto+sha3"
DEL_FLAGS="-O2 -D_FORTIFY_SOURCE=2"
PIN=""
if command -v taskset >/dev/null 2>&1; then PIN="taskset -c 0"; fi

build_one()
{
    local tag="$1"; shift
    local dir="build_e3_${tag}"
    echo "===== Build [$tag] ($dir) at -O3 ====="
    rm -rf "$dir"; mkdir -p "$dir" && cd "$dir"
    cmake \
        -DHITLS_BUILD_BENCHMARK=ON \
        -DHITLS_CRYPTO_FRODOKEM=ON \
        -D_HITLS_COMPILE_OPTIONS_DEL="${DEL_FLAGS}" \
        -DCMAKE_C_FLAGS="-O3 ${ARCH_FLAGS}" \
        "$@" \
        ..
    make -j"$JOBS" openhitls_benchmark
    cd ..
}

run_one()
{
    local tag="$1"
    local dir="build_e3_${tag}"
    local out="results/e3_kem_${tag}_O3.txt"
    mkdir -p results
    echo "===== Run [$tag] KEM end-to-end, -O3, t=$ITERS ====="
    $PIN ./"$dir"/testcode/benchmark/openhitls_benchmark -a 'frodokem*' -t "$ITERS" > "$out"
    echo "  saved: $out"
    echo
}

NEON_FLAGS=(-DHITLS_ASM_ARMV8=ON -DHITLS_CRYPTO_FRODOKEM_ASM=ON -DHITLS_CRYPTO_FRODOKEM_ARMV8=ON)

if [[ "${1:-all}" == "all" || "${1:-all}" == "build" ]]; then
    build_one ref                          # C reference at -O3 (no NEON)
    build_one neon "${NEON_FLAGS[@]}"       # NEON at -O3
fi

if [[ "${1:-all}" == "all" || "${1:-all}" == "run" ]]; then
    run_one ref
    run_one neon
    echo "Done. -O3 end-to-end results:"
    echo "  results/e3_kem_ref_O3.txt"
    echo "  results/e3_kem_neon_O3.txt"
    echo
    echo "Sanity check (verify -O3 actually applied): the C-ref KeyGen should"
    echo "be noticeably faster than the -O2 numbers in the paper's Table 2."
fi
