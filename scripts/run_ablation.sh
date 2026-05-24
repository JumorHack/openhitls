#!/usr/bin/env bash
#
# Experiment 1: Ablation Study
#
# Builds 4 configurations and measures the AS+E inner kernel cycles on
# Frodo-640-AES (and the others, for context):
#
#   (A) Baseline C       — HITLS_CRYPTO_FRODOKEM_ARMV8 OFF
#   (B) NEON naive       — ARMV8 ON, FRODO_NAIVE_SCHEDULE, DISABLE_NEON_SAMPLE
#   (C) NEON diagonal    — ARMV8 ON, DISABLE_NEON_SAMPLE
#   (D) NEON full        — ARMV8 ON (default)
#
# Each variant is built into a separate `build_<tag>/` directory.  Set
# ITERS_NEON / ITERS_REF via env to control sample size (defaults 1000 / 100).
#
# Usage:
#   bash scripts/run_ablation.sh           # builds + runs all 4
#   bash scripts/run_ablation.sh build     # just (re)build
#   bash scripts/run_ablation.sh run       # just run with existing builds

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ITERS_NEON=${ITERS_NEON:-1000}
ITERS_REF=${ITERS_REF:-100}
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu)

CMAKE_BASE=(
    -DHITLS_BUILD_BENCHMARK=ON
    -DHITLS_CRYPTO_FRODOKEM=ON
)
COMMON_FLAGS="-O2 -march=armv8.4-a+crypto+sha3"

build_one()
{
    local tag="$1"; shift
    local dir="build_${tag}"
    local extra_flags="$1"; shift
    echo "===== Build [$tag] ($dir) ====="
    rm -rf "$dir"
    mkdir -p "$dir" && cd "$dir"
    cmake "${CMAKE_BASE[@]}" \
        "$@" \
        -DCMAKE_C_FLAGS="${COMMON_FLAGS} ${extra_flags}" \
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
}

if [[ "${1:-all}" == "all" || "${1:-all}" == "build" ]]; then
    # (A) baseline C - no NEON
    build_one A_baseline_c ""
    # (B) NEON naive scheduling, scalar sampling
    build_one B_neon_naive "-DFRODO_NAIVE_SCHEDULE -DDISABLE_NEON_SAMPLE" \
        -DHITLS_ASM_ARMV8=ON -DHITLS_CRYPTO_FRODOKEM_ASM=ON -DHITLS_CRYPTO_FRODOKEM_ARMV8=ON
    # (C) NEON diagonal scheduling, scalar sampling
    build_one C_neon_diag  "-DDISABLE_NEON_SAMPLE" \
        -DHITLS_ASM_ARMV8=ON -DHITLS_CRYPTO_FRODOKEM_ASM=ON -DHITLS_CRYPTO_FRODOKEM_ARMV8=ON
    # (D) full NEON (matrix diagonal + NEON sampling)
    build_one D_neon_full  "" \
        -DHITLS_ASM_ARMV8=ON -DHITLS_CRYPTO_FRODOKEM_ASM=ON -DHITLS_CRYPTO_FRODOKEM_ARMV8=ON
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
    echo "Done. Ablation outputs:"
    ls -l results/ablation_*.txt
    echo
    echo "Quick read:"
    for f in results/ablation_{A_baseline_c,B_neon_naive,C_neon_diag,D_neon_full}.txt; do
        echo "----- $f -----"
        grep -E "frodo-640-aes" "$f" | head -1
    done
fi
