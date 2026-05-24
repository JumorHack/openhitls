#!/usr/bin/env bash
#
# Experiment 5: L1d / LLC cache impact of S^T -> S pre-transpose.
#
# Compares NEON build (does the 21 KB transpose) vs C-ref build (no transpose)
# for KEM end-to-end on the largest parameter set, which has the worst-case
# L1d pressure.
#
# CAVEATS on Graviton 3:
#   * perf is restricted to ~4 hardware counters at a time; if you ask for too
#     many events, some get <not counted>.  We split the run into two passes.
#   * LLC events (perf alias) are not exposed on this part.  We substitute with
#     the raw ARM PMU event 0x2A "LL_CACHE_RD" (last-level cache read access)
#     and 0x37 "LL_CACHE_MISS_RD".  These are part of the ARMv8 Cache effects
#     extension and are visible on Neoverse V1.
#   * Pattern must NOT include hyphens inside the algorithm portion the way
#     the harness parses it; safer to use `frodokem*` (all params, all ops).
#
# Pre-req: build_neon/ and build_ref/ already built (from earlier steps).
# Usage:   bash scripts/run_cache.sh

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
mkdir -p results

# To get a meaningful counter, iterations need to be high enough to amortise
# perf-stat startup cost.  500 iters * 6 params * 3 ops ~= 30s per variant.
ITERS=${ITERS:-500}

# Pass 1: standard L1d events (cycles + L1d loads + L1d misses).  perf normally
# allows 4 hardware events simultaneously on V1.
EV_L1="cycles,instructions,L1-dcache-loads,L1-dcache-load-misses"

# Pass 2: last-level via raw ARM PMU events (perf prefix `r<hex>` for raw).
# 0x32 = LL_CACHE     LL cache access (Neoverse V1 PMU spec)
# 0x33 = LL_CACHE_MISS
# Confirm names with:  perf list | grep -i ll_cache
EV_LL="r32,r33"

run_one()
{
    local variant="$1"
    local events="$2"
    local out="$3"
    local bin="./build_${variant}/testcode/benchmark/openhitls_benchmark"
    if [[ ! -x "$bin" ]]; then
        echo "ERROR: $bin not found." >&2
        return 1
    fi
    echo "[$variant] events=$events"
    perf stat -e "$events" \
        "$bin" -a 'frodokem*' -t "$ITERS" \
        > "$out" 2>&1
    echo "  saved: $out"
}

for variant in neon ref; do
    run_one "$variant" "$EV_L1" "results/cache_${variant}_L1.txt"
    # LL pass may fail on some images; tolerate failure.
    run_one "$variant" "$EV_LL" "results/cache_${variant}_LL.txt" || \
        echo "  WARN: LL_CACHE raw events not available, skipping"
done

echo
echo "===== Summary (compare NEON vs ref) ====="
for variant in neon ref; do
    echo
    echo "--- ${variant} L1 ---"
    grep -E "L1-dcache|cycles|instructions" "results/cache_${variant}_L1.txt" | grep -v '^#' || true
    if [[ -s "results/cache_${variant}_LL.txt" ]]; then
        echo "--- ${variant} LL (raw) ---"
        grep -E "r32|r33" "results/cache_${variant}_LL.txt" | grep -v '^#' || true
    fi
done

echo
echo "L1d miss rate = L1-dcache-load-misses / L1-dcache-loads"
echo "LL  miss rate = r33 / r32"
