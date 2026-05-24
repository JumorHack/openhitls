#!/usr/bin/env bash
#
# Experiment 5: L1d / LLC cache impact of S^T → S pre-transpose.
#
# Compares NEON build (does the 21 KB transpose) vs C-ref build (no transpose)
# for KEM end-to-end on Frodo-1344-AES (largest matrix, worst-case L1d pressure).
#
# Pre-req: build_neon/ and build_ref/ already built.
# Usage: bash scripts/run_cache.sh

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

mkdir -p results
ITERS=${ITERS:-1000}

EVENTS="cycles,instructions,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses"

for variant in neon ref; do
    BIN="./build_${variant}/testcode/benchmark/openhitls_benchmark"
    if [[ ! -x "$BIN" ]]; then
        echo "ERROR: $BIN not found. Build it first." >&2
        exit 1
    fi
    echo "===== Cache measurement: ${variant} ====="
    perf stat -e "$EVENTS" \
        "$BIN" -a 'frodokem-1344-aes' -t "$ITERS" \
        > "results/cache_${variant}.txt" 2>&1
    echo "  saved: results/cache_${variant}.txt"
done

echo
echo "Summary:"
for variant in neon ref; do
    echo
    echo "--- ${variant} ---"
    grep -E "L1-dcache|LLC|cycles|instructions" "results/cache_${variant}.txt" \
        | grep -v "^#"
done

echo
echo "L1d miss rate = L1-dcache-load-misses / L1-dcache-loads"
echo "LLC miss rate = LLC-load-misses        / LLC-loads"
