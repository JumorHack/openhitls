#!/usr/bin/env bash
#
# Experiment E1a: MLA schedule comparison on a single core (Neoverse V1).
#
# Builds and runs the AS+E micro benchmark under THREE MLA schedules, all
# with identical flags (NEON on, scalar sampler, same -march/-O), so the
# only difference is the order of the 16 MLA instructions:
#
#   row-at-a-time  v0,v0,v0,v0, v1,v1,...   (config E, FRODO_NAIVE_SCHEDULE)
#   round-robin    v0,v1,v2,v3, v0,v1,...   (config B, FRODO_RR_SCHEDULE)
#   diagonal       Latin-square pairing     (config C, default)
#
# The §4.3 accumulate-forwarding analysis predicts the three are
# performance-equivalent on V1 (forwarding latency 1) and on A72
# (forwarding latency 2 == Q-form issue interval).  This experiment
# confirms it empirically on V1.
#
# Usage:
#   bash scripts/run_e1a.sh            # build + run all three
#   bash scripts/run_e1a.sh build      # just (re)build
#   bash scripts/run_e1a.sh run        # just run existing builds
#
# Env override:
#   ITERS=2000 bash scripts/run_e1a.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ITERS=${ITERS:-2000}
WARMUP=${WARMUP:-200}
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
COMMON_FLAGS="-O2 -march=armv8.4-a+crypto+sha3"

# Pin to a single core if taskset is available (steadier cycle counts).
PIN=""
if command -v taskset >/dev/null 2>&1; then PIN="taskset -c 0"; fi

build_one()
{
    local tag="$1"; shift
    local dir="build_e1a_${tag}"
    echo "===== Build [$tag] ($dir) ====="
    rm -rf "$dir"
    mkdir -p "$dir" && cd "$dir"
    cmake \
        -DHITLS_BUILD_BENCHMARK=ON \
        -DHITLS_CRYPTO_FRODOKEM=ON \
        -DHITLS_ASM_ARMV8=ON \
        -DHITLS_CRYPTO_FRODOKEM_ASM=ON \
        -DHITLS_CRYPTO_FRODOKEM_ARMV8=ON \
        -DDISABLE_NEON_SAMPLE=ON \
        -DCMAKE_C_FLAGS="${COMMON_FLAGS}" \
        "$@" \
        ..
    make -j"$JOBS" frodokem_micro
    cd ..
}

run_one()
{
    local tag="$1"
    local dir="build_e1a_${tag}"
    local out="results/e1a_${tag}.txt"
    mkdir -p results
    echo "===== Run [$tag] iters=$ITERS warmup=$WARMUP ====="
    $PIN ./"$dir"/testcode/benchmark/frodokem_micro "$ITERS" "$WARMUP" > "$out"
    echo "  saved: $out"
    head -6 "$out"     # diagnostic header: confirms which schedule ran
    echo
}

if [[ "${1:-all}" == "all" || "${1:-all}" == "build" ]]; then
    build_one rowwise -DFRODO_NAIVE_SCHEDULE=ON   # config E
    build_one rr      -DFRODO_RR_SCHEDULE=ON      # config B
    build_one diag                                # config C (default)
fi

if [[ "${1:-all}" == "all" || "${1:-all}" == "run" ]]; then
    run_one rowwise
    run_one rr
    run_one diag

    echo "Done. AS+E (frodo-640-aes) median across the three schedules:"
    for tag in rowwise rr diag; do
        printf '  %-8s ' "$tag"
        grep "frodo-640-aes" "results/e1a_${tag}.txt" | head -1
    done
fi
