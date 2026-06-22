#!/usr/bin/env bash
#
# run_e9_profile.sh -- E9: localise the openHiTLS-vs-liboqs gap by profiling
# KeyGen / Encaps / Decaps of BOTH libraries (FrodoKEM-640-AES) with perf and
# reporting per-operation, per-function self-time.
#
# Both built with the hardware-AES PRG; openHiTLS NEON at -O2 -g, liboqs from
# its existing Release build.  Output: results_v9/.
#
# Usage: bash scripts/run_e9_profile.sh
# Env:   ITERS (default 12000)

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUT=results_v9; mkdir -p "$OUT"
ARCH="-march=armv8.4-a+crypto+sha3"
HWAES=(-DHITLS_ASM_ARMV8=ON -DHITLS_CRYPTO_AES_ASM=ON -DHITLS_CRYPTO_AES_ARMV8=ON)
NEON=(-DHITLS_CRYPTO_FRODOKEM_ASM=ON -DHITLS_CRYPTO_FRODOKEM_ARMV8=ON)
ITERS=${ITERS:-12000}
LOQS=e4_ext/liboqs/build
PIN=""; command -v taskset >/dev/null 2>&1 && PIN="taskset -c 0"

# ---- build openHiTLS profiling driver (NEON + HW-AES, -O2 -g for symbols) ----
DIR=build_v9_prof
echo "===== build openHiTLS frodokem_prof ====="
rm -rf "$DIR"; mkdir -p "$DIR"; ( cd "$DIR"
    cmake -DHITLS_BUILD_BENCHMARK=ON -DHITLS_CRYPTO_FRODOKEM=ON \
          "${HWAES[@]}" "${NEON[@]}" \
          -DCMAKE_C_FLAGS="-O2 -g -fno-omit-frame-pointer ${ARCH}" .. >/dev/null
    make -j"$(nproc)" frodokem_prof >/dev/null )
OH=./$DIR/testcode/benchmark/frodokem_prof

# ---- build liboqs profiling driver against the existing Release lib ----
echo "===== build liboqs frodo_oqs_prof ====="
gcc -O2 -g -I "$LOQS/include" scripts/frodo_oqs_prof.c "$LOQS/lib/liboqs.a" \
    -o /tmp/frodo_oqs_prof -lm -lpthread
OQ=/tmp/frodo_oqs_prof

# ---- sanity: confirm both run ----
"$OH" kg 50 2>&1 | tail -1
"$OQ" kg 50 2>&1 | tail -1

# ---- profile each (library x operation) ----
prof() {   # prof <tag> <bin> <op>
    local tag=$1 bin=$2 op=$3
    $PIN perf record -F 1999 \
        -o "$OUT/perf_${tag}_${op}.data" -- "$bin" "$op" "$ITERS" 2>>"$OUT/perf.log"
    {
        echo "===================================================================="
        echo "== $tag  $op   (self-time %, top functions)"
        echo "===================================================================="
        perf report --stdio --no-children --percent-limit 0.8 \
            -i "$OUT/perf_${tag}_${op}.data" 2>/dev/null \
            | grep -E "^[[:space:]]+[0-9]+\." | head -20
        echo
    } | tee -a "$OUT/e9_profile.txt"
}

: > "$OUT/e9_profile.txt"
for op in kg en de; do
    prof openhitls "$OH" "$op"
    prof liboqs    "$OQ" "$op"
done

echo "Done -> $OUT/e9_profile.txt"
tar czf results_v9.tar.gz "$OUT"
