#!/usr/bin/env bash
#
# Experiment 1: Ablation Study
#
# Four build configurations, each into its own build_<tag>/ directory:
#
#   (A) Baseline C       HITLS_CRYPTO_FRODOKEM_ARMV8 OFF
#   (B) NEON naive       ARMV8 ON, FRODO_NAIVE_SCHEDULE=ON, DISABLE_NEON_SAMPLE=ON
#   (C) NEON diagonal    ARMV8 ON,                          DISABLE_NEON_SAMPLE=ON
#   (D) NEON full        ARMV8 ON
#
# Macros are passed as proper CMake options so they propagate via
# target_compile_definitions — NOT via -DCMAKE_C_FLAGS (which had ordering
# issues with openHiTLS's own -O2/_FORTIFY_SOURCE injection).
#
# Each binary prints "Schedule:" and "Sampler:" lines at startup so you can
# eyeball whether the macros took effect.
#
# Env override:
#   ITERS_NEON=1000 (default)   ITERS_REF=100 (default)
#
# Usage:
#   bash scripts/run_ablation.sh           # build + run all 4
#   bash scripts/run_ablation.sh build     # just (re)build
#   bash scripts/run_ablation.sh run       # just run with existing builds

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ITERS_NEON=${ITERS_NEON:-1000}
ITERS_REF=${ITERS_REF:-100}
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
COMMON_FLAGS="-O2 -march=armv8.4-a+crypto+sha3"

build_one()
{
    local tag="$1"; shift
    local dir="build_${tag}"
    echo "===== Build [$tag] ($dir) ====="
    rm -rf "$dir"
    mkdir -p "$dir" && cd "$dir"
    cmake \
        -DHITLS_BUILD_BENCHMARK=ON \
        -DHITLS_CRYPTO_FRODOKEM=ON \
        -DCMAKE_C_FLAGS="${COMMON_FLAGS}" \
        "$@" \
        ..
    make -j"$JOBS" frodokem_micro openhitls_benchmark
    cd ..
}

run_one()
{
    local tag="$1"
    local iters="$2"
    local dir="build_${tag}"
    local out="results/ablation_${tag}.txt"
    mkdir -p results
    echo "===== Run [$tag] iters=$iters ====="
    ./"$dir"/testcode/benchmark/frodokem_micro "$iters" > "$out"
    echo "  saved: $out"
    # print the diagnostic header so we know what we got
    head -8 "$out"
    echo
}

if [[ "${1:-all}" == "all" || "${1:-all}" == "build" ]]; then
    # (A) baseline C - no NEON at all
    build_one A_baseline_c
    # (B) NEON: outer-product, NAIVE schedule, scalar sampler
    build_one B_neon_naive \
        -DHITLS_ASM_ARMV8=ON \
        -DHITLS_CRYPTO_FRODOKEM_ASM=ON \
        -DHITLS_CRYPTO_FRODOKEM_ARMV8=ON \
        -DFRODO_NAIVE_SCHEDULE=ON \
        -DDISABLE_NEON_SAMPLE=ON
    # (C) NEON: outer-product, DIAGONAL schedule, scalar sampler
    build_one C_neon_diag \
        -DHITLS_ASM_ARMV8=ON \
        -DHITLS_CRYPTO_FRODOKEM_ASM=ON \
        -DHITLS_CRYPTO_FRODOKEM_ARMV8=ON \
        -DDISABLE_NEON_SAMPLE=ON
    # (D) full NEON (matrix diagonal + NEON sampling)
    build_one D_neon_full \
        -DHITLS_ASM_ARMV8=ON \
        -DHITLS_CRYPTO_FRODOKEM_ASM=ON \
        -DHITLS_CRYPTO_FRODOKEM_ARMV8=ON
fi

if [[ "${1:-all}" == "all" || "${1:-all}" == "run" ]]; then
    run_one A_baseline_c "$ITERS_REF"
    run_one B_neon_naive "$ITERS_NEON"
    run_one C_neon_diag  "$ITERS_NEON"
    run_one D_neon_full  "$ITERS_NEON"

    # KEM end-to-end for (D) only
    echo "===== KEM end-to-end for (D) ====="
    perf stat -e cycles,instructions,task-clock \
        ./build_D_neon_full/testcode/benchmark/openhitls_benchmark \
        -a 'frodokem*' -t "$ITERS_NEON" \
        > results/ablation_D_kem.txt 2>&1

    echo
    echo "Done. Quick read of AS+E for frodo-640-aes:"
    for f in results/ablation_{A_baseline_c,B_neon_naive,C_neon_diag,D_neon_full}.txt; do
        echo "$(basename "$f"):"
        grep "frodo-640-aes" "$f" | head -1
    done
fi
