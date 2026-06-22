#!/usr/bin/env bash
#
# run_e8_dudect.sh -- E8: dudect constant-time test of the NEON CDF sampler
# FrodoCommonSampleNFromR.
#
# Fetches the header-only dudect (oreparaz/dudect), builds the NEON library
# with hardware AES, compiles the frodokem_dudect harness against it, and runs
# the fixed-vs-random test.  A constant-time sampler keeps Welch |t| < 4.5.
#
# Output: results_v8/e8_dudect_sampler.txt  (+ results_v8.tar.gz)
# Usage:  bash scripts/run_e8_dudect.sh
# Env:    DUDECT_BATCHES (default 2000; ~1e7 measurements)
#
# dudect times via the aarch64 virtual counter (CNTVCT_EL0), so it does NOT
# need perf_event access; pinning to one core steadies the statistics.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

JOBS=$(nproc 2>/dev/null || echo 4)
OUT="results_v8"; mkdir -p "$OUT"
ARCH="-march=armv8.4-a+crypto+sha3"
HWAES=(-DHITLS_ASM_ARMV8=ON -DHITLS_CRYPTO_AES_ASM=ON -DHITLS_CRYPTO_AES_ARMV8=ON)
NEON=(-DHITLS_CRYPTO_FRODOKEM_ASM=ON -DHITLS_CRYPTO_FRODOKEM_ARMV8=ON)
DUDECT_H="testcode/benchmark/dudect.h"
PIN=""; command -v taskset >/dev/null 2>&1 && PIN="taskset -c 0"

# ---- fetch dudect.h (header-only) -------------------------------------------
if [ ! -f "$DUDECT_H" ]; then
    echo "===== fetching dudect.h ====="
    URL="https://raw.githubusercontent.com/oreparaz/dudect/master/src/dudect.h"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$DUDECT_H" "$URL"
    else
        wget -qO "$DUDECT_H" "$URL"
    fi
fi
echo "dudect.h: $(wc -l < "$DUDECT_H") lines"

# ---- build (NEON + hardware AES) --------------------------------------------
DIR=build_v8_dudect
echo "===== build (NEON, HW-AES) $DIR ====="
rm -rf "$DIR"; mkdir -p "$DIR"; ( cd "$DIR"
    cmake -DHITLS_BUILD_BENCHMARK=ON -DHITLS_CRYPTO_FRODOKEM=ON \
          "${HWAES[@]}" "${NEON[@]}" -DCMAKE_C_FLAGS="-O2 ${ARCH}" .. >/dev/null
    make -j"$JOBS" frodokem_dudect )

BIN="./$DIR/testcode/benchmark/frodokem_dudect"
if [ ! -x "$BIN" ]; then
    echo "ERROR: $BIN not built (check that dudect.h was fetched before cmake)"; exit 1
fi

# ---- run --------------------------------------------------------------------
echo "===== run dudect (this takes a few minutes) ====="
DUDECT_BATCHES="${DUDECT_BATCHES:-2000}" $PIN "$BIN" | tee "$OUT/e8_dudect_sampler.txt"

echo
echo "===== verdict (last lines) ====="
tail -3 "$OUT/e8_dudect_sampler.txt"
echo "max |t| observed:"
grep -oE "max t:[^,]*" "$OUT/e8_dudect_sampler.txt" | tail -1 || true

tar czf results_v8.tar.gz "$OUT"
echo "Done -> results_v8/ + results_v8.tar.gz"
