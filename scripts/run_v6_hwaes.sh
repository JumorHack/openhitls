#!/usr/bin/env bash
#
# run_v6_hwaes.sh -- re-measure FrodoKEM with HARDWARE AES enabled (results_v6).
#
# WHY THIS EXISTS
# ---------------
# Investigation of the openHiTLS-vs-liboqs ~8x gap found it is NOT algorithmic:
# the benchmark builds used the *software* T-box AES because the CMake feature
# HITLS_CRYPTO_AES_ARMV8 defaults OFF (only -march=...+crypto was passed, which
# is assembler capability, not feature selection).  On-the-fly A generation
# therefore ran at ~150 cycles/AES-block instead of ~20 with the AESE/AESMC
# hardware path -- exactly the measured 7,651,402 cy / 51,200 blocks for
# Frodo-640.  liboqs uses ARM crypto extensions, hence ~8x faster.
#
# This script rebuilds EVERY configuration with hardware AES turned on (in both
# the C reference and the NEON build, since Gen(A) is shared PRG code) and
# regenerates the four tables the paper needs:
#   Table 2  (kem, -O2 end-to-end)   <- kem_ref_O2_fixed.txt + ablation_D_kem.txt
#   Table 3  (micro, -O2 component)  <- e2_ref_full.txt + e2_neon_full.txt
#   macdecomp (Gen / MAC split)      <- e2_{ref,neon}_{full,gen}.txt
#   o3kem    (-O3 end-to-end)        <- e3_kem_{ref,neon}_O3.txt
#
# SHA-3 is deliberately left as C (matches liboqs's "SHA-3: C"), so the AES
# variants compare HW-AES vs HW-AES and the SHAKE variants compare C-Keccak vs
# C-Keccak -- fair in both directions.
#
# Output: results_v6/  +  results_v6.tar.gz
#
# Usage:   bash scripts/run_v6_hwaes.sh
# Env:     ITERS_NEON (default 2000)  ITERS_REF (default 200)  ITERS_KEM (default 1000)
#
# Run AFTER the KAT correctness check (see the runbook).  Lock frequency and
# relax perf first:
#   sudo cpupower frequency-set -g performance 2>/dev/null || true
#   sudo sysctl kernel.perf_event_paranoid=-1

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ITERS_NEON=${ITERS_NEON:-2000}
ITERS_REF=${ITERS_REF:-200}
ITERS_KEM=${ITERS_KEM:-1000}
JOBS=$(nproc 2>/dev/null || echo 4)

OUT="results_v6"; mkdir -p "$OUT"

ARCH="-march=armv8.4-a+crypto+sha3"
# *** THE FIX: enable the hardware AES (AESE/AESMC) feature in every build ***
HWAES=(-DHITLS_ASM_ARMV8=ON -DHITLS_CRYPTO_AES_ASM=ON -DHITLS_CRYPTO_AES_ARMV8=ON)
# our FrodoKEM NEON kernels (outer-product matrix + 32-way CDF sampler):
NEON=(-DHITLS_CRYPTO_FRODOKEM_ASM=ON -DHITLS_CRYPTO_FRODOKEM_ARMV8=ON)
DEL="-O2 -D_FORTIFY_SOURCE=2"   # openHiTLS injects these AFTER CMAKE_C_FLAGS; strip for -O3

PIN=""; command -v taskset >/dev/null 2>&1 && PIN="taskset -c 0"

# ---- build helpers (mirror run_e2/run_e3/run_ablation exactly, + HWAES) ----
build_o2() {            # build_o2 <dir> <target> [extra cmake...]
    local dir="$1" tgt="$2"; shift 2
    echo "===== build (-O2, HW-AES) $dir ====="
    rm -rf "$dir"; mkdir -p "$dir"; ( cd "$dir"
        cmake -DHITLS_BUILD_BENCHMARK=ON -DHITLS_CRYPTO_FRODOKEM=ON \
              "${HWAES[@]}" -DCMAKE_C_FLAGS="-O2 ${ARCH}" "$@" .. >/dev/null
        make -j"$JOBS" "$tgt" >/dev/null )
}
build_o3() {            # build_o3 <dir> <target> [extra cmake...]
    local dir="$1" tgt="$2"; shift 2
    echo "===== build (-O3, HW-AES) $dir ====="
    rm -rf "$dir"; mkdir -p "$dir"; ( cd "$dir"
        cmake -DHITLS_BUILD_BENCHMARK=ON -DHITLS_CRYPTO_FRODOKEM=ON \
              "${HWAES[@]}" -D_HITLS_COMPILE_OPTIONS_DEL="${DEL}" \
              -DCMAKE_C_FLAGS="-O3 ${ARCH}" "$@" .. >/dev/null
        make -j"$JOBS" "$tgt" >/dev/null )
}
micro() { $PIN ./"$1"/testcode/benchmark/frodokem_micro "$2"; }
kem()   { $PIN ./"$1"/testcode/benchmark/openhitls_benchmark -a 'frodokem*' -t "$2"; }

# ============================================================
# E2 : PRG/MAC decomposition  ->  Table 3 (micro) + macdecomp
# ============================================================
build_o2 build_v6_e2_ref_full  frodokem_micro
build_o2 build_v6_e2_ref_gen   frodokem_micro  -DFRODO_BENCH_GEN_ONLY=ON
build_o2 build_v6_e2_neon_full frodokem_micro  "${NEON[@]}"
build_o2 build_v6_e2_neon_gen  frodokem_micro  "${NEON[@]}" -DFRODO_BENCH_GEN_ONLY=ON

micro build_v6_e2_ref_full  "$ITERS_REF"  > "$OUT/e2_ref_full.txt"
micro build_v6_e2_ref_gen   "$ITERS_REF"  > "$OUT/e2_ref_gen.txt"
micro build_v6_e2_neon_full "$ITERS_NEON" > "$OUT/e2_neon_full.txt"
micro build_v6_e2_neon_gen  "$ITERS_NEON" > "$OUT/e2_neon_gen.txt"

# ============================================================
# E3 : -O3 end-to-end KEM  ->  Table o3kem
# ============================================================
build_o3 build_v6_e3_ref  openhitls_benchmark
build_o3 build_v6_e3_neon openhitls_benchmark "${NEON[@]}"
kem build_v6_e3_ref  "$ITERS_KEM" > "$OUT/e3_kem_ref_O3.txt"
kem build_v6_e3_neon "$ITERS_KEM" > "$OUT/e3_kem_neon_O3.txt"

# ============================================================
# -O2 end-to-end KEM  ->  Table 2 (kem)
#   ref column  = kem_ref_O2_fixed.txt
#   NEON column = ablation_D_kem.txt
# ============================================================
build_o2 build_v6_kem_ref_o2  openhitls_benchmark
build_o2 build_v6_kem_neon_o2 openhitls_benchmark "${NEON[@]}"
kem build_v6_kem_ref_o2  "$ITERS_KEM" > "$OUT/kem_ref_O2_fixed.txt"
kem build_v6_kem_neon_o2 "$ITERS_KEM" > "$OUT/ablation_D_kem.txt"

# ============================================================
# Sanity check + package
# ============================================================
echo
echo "===== SANITY: Frodo-640-AES Gen(A) should now be ~1.0M cy (was ~7.65M) ====="
echo "GEN-only (ref) :"; grep '^frodo-640-aes ' "$OUT/e2_ref_gen.txt"  | head -1
echo "GEN-only (neon):"; grep '^frodo-640-aes ' "$OUT/e2_neon_gen.txt" | head -1
echo "FULL AS+E (ref/neon):"
grep '^frodo-640-aes ' "$OUT/e2_ref_full.txt"  | head -1
grep '^frodo-640-aes ' "$OUT/e2_neon_full.txt" | head -1
echo "-O2 KeyGen 640-aes (ref/neon, ms): expect ref ~1.8 / neon ~0.6 (was 4.42 / 3.18)"
grep 'frodokem-640-aes keyGen' "$OUT/kem_ref_O2_fixed.txt" "$OUT/ablation_D_kem.txt" || true

tar czf results_v6.tar.gz "$OUT"
echo
echo "Done. Bring back results_v6.tar.gz (or the results_v6/ dir)."
echo "If Gen(A) is still ~7.6M, hardware AES did NOT take effect -- check the"
echo "cmake output for 'HITLS_CRYPTO_AES_ARMV8' and that as/ld accept +crypto."
