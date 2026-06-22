#!/usr/bin/env bash
#
# run_v7_ablation_hwaes.sh -- re-measure the two ablation tables with HARDWARE AES.
#
# WHY THIS EXISTS
# ---------------
# results_v6 re-measured the main tables (Table 2/3/macdecomp/o3kem) with the
# ARM hardware-AES core enabled, dropping Gen(A) for Frodo-640-AES from 7.65M
# to 0.67M cycles.  Two ablation tables were left on the OLD software-AES build
# and now contradict the main tables:
#   * tab:ablation (paper Sec 6.6) -- MLA-schedule comparison (E1a):
#         row-at-a-time / round-robin / diagonal, NEON kernel, scalar sampler.
#   * tab:opt       (paper Sec 6.4) -- compiler opt-level study:
#         AS+E / S'A+E' / sampler at -O0/-O2/-O3, C reference vs NEON.
#
# This script rebuilds BOTH with the hardware-AES feature on (so Gen(A) matches
# results_v6) and regenerates the data into results_v7/.
#
# NOTE for tab:ablation: the absolute schedule spread (~39k cycles between the
# fastest/slowest schedule) is unchanged by the PRG, but against the ~8x smaller
# hardware-AES AS+E it is now ~4% rather than 0.49%.  Check whether the spread
# survives or collapses into noise -- it bears on the paper's contribution 3.
#
# Output:  results_v7/  +  results_v7.tar.gz
# Usage:   bash scripts/run_v7_ablation_hwaes.sh
# Env:     ITERS_ABL (2000)  ITERS_OPT_NEON (1000)  ITERS_OPT_REF (100)  WARMUP (200)
#
# Run after `sudo sysctl kernel.perf_event_paranoid=-1` (already -1 on the box).

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ITERS_ABL=${ITERS_ABL:-2000}
ITERS_OPT_NEON=${ITERS_OPT_NEON:-1000}
ITERS_OPT_REF=${ITERS_OPT_REF:-100}
WARMUP=${WARMUP:-200}
JOBS=$(nproc 2>/dev/null || echo 4)
OUT="results_v7"; mkdir -p "$OUT"

ARCH="-march=armv8.4-a+crypto+sha3"
# *** hardware AES (AESE/AESMC) -- the v6 fix, enabled in EVERY build here ***
HWAES=(-DHITLS_ASM_ARMV8=ON -DHITLS_CRYPTO_AES_ASM=ON -DHITLS_CRYPTO_AES_ARMV8=ON)
# our FrodoKEM NEON kernels (outer-product matrix + CDF sampler):
NEON=(-DHITLS_CRYPTO_FRODOKEM_ASM=ON -DHITLS_CRYPTO_FRODOKEM_ARMV8=ON)
# openHiTLS injects "-O2 -D_FORTIFY_SOURCE=2" AFTER CMAKE_C_FLAGS; strip so our -O wins
DEL="-O2 -D_FORTIFY_SOURCE=2"

PIN=""; command -v taskset >/dev/null 2>&1 && PIN="taskset -c 0"
micro() { $PIN ./"$1"/testcode/benchmark/frodokem_micro "$2" "${3:-$WARMUP}"; }

build_abl() {            # build_abl <dir> [schedule flag...]  (NEON, scalar sampler, -O2)
    local dir="$1"; shift
    echo "===== build (ablation -O2 HW-AES) $dir ====="
    rm -rf "$dir"; mkdir -p "$dir"; ( cd "$dir"
        cmake -DHITLS_BUILD_BENCHMARK=ON -DHITLS_CRYPTO_FRODOKEM=ON \
              "${HWAES[@]}" "${NEON[@]}" -DDISABLE_NEON_SAMPLE=ON \
              -DCMAKE_C_FLAGS="-O2 ${ARCH}" "$@" .. >/dev/null
        make -j"$JOBS" frodokem_micro >/dev/null )
}
build_opt() {            # build_opt <dir> <-Ox> [extra cmake...]
    local dir="$1" opt="$2"; shift 2
    echo "===== build (opt ${opt} HW-AES) $dir ====="
    rm -rf "$dir"; mkdir -p "$dir"; ( cd "$dir"
        cmake -DHITLS_BUILD_BENCHMARK=ON -DHITLS_CRYPTO_FRODOKEM=ON \
              "${HWAES[@]}" -D_HITLS_COMPILE_OPTIONS_DEL="${DEL}" \
              -DCMAKE_C_FLAGS="${opt} ${ARCH}" "$@" .. >/dev/null
        make -j"$JOBS" frodokem_micro >/dev/null )
}

# ============================================================
# Part A : MLA schedule ablation (NEON, scalar sampler) -> tab:ablation
# ============================================================
build_abl build_v7_e1a_rowwise -DFRODO_NAIVE_SCHEDULE=ON   # config E (row-at-a-time)
build_abl build_v7_e1a_rr      -DFRODO_RR_SCHEDULE=ON      # config B (round-robin)
build_abl build_v7_e1a_diag                                # config C (diagonal, default)

micro build_v7_e1a_rowwise "$ITERS_ABL" > "$OUT/e1a_rowwise.txt"
micro build_v7_e1a_rr      "$ITERS_ABL" > "$OUT/e1a_rr.txt"
micro build_v7_e1a_diag    "$ITERS_ABL" > "$OUT/e1a_diag.txt"

# ============================================================
# Part B : compiler opt-level study (C ref vs NEON) -> tab:opt
# ============================================================
for OPT in O0 O2 O3; do
    build_opt "build_v7_opt_${OPT}_ref"  "-${OPT}"
    micro     "build_v7_opt_${OPT}_ref"  "$ITERS_OPT_REF"  > "$OUT/opt_${OPT}_ref.txt"
    build_opt "build_v7_opt_${OPT}_neon" "-${OPT}" "${NEON[@]}"
    micro     "build_v7_opt_${OPT}_neon" "$ITERS_OPT_NEON" > "$OUT/opt_${OPT}_neon.txt"
done

# ============================================================
# Sanity + package
# ============================================================
echo
echo "===== SANITY (Frodo-640-AES, AS+E median = 3rd field) ====="
echo "--- schedule ablation: AS+E should be ~0.94M (HW-AES); 3 schedules within ~0.5% ---"
for t in rowwise rr diag; do printf '  %-8s ' "$t"; grep '^frodo-640-aes ' "$OUT/e1a_${t}.txt" | head -1; done
echo "--- opt-level -O2: should match results_v6 (ref ~3.96M / neon ~0.95M) ---"
printf '  ref  '; grep '^frodo-640-aes ' "$OUT/opt_O2_ref.txt"  | head -1
printf '  neon '; grep '^frodo-640-aes ' "$OUT/opt_O2_neon.txt" | head -1
echo "(if AS+E is ~7-8M, hardware AES did NOT take effect -- check cmake output above)"

tar czf results_v7.tar.gz "$OUT"
echo
echo "ALL DONE -> results_v7/ + results_v7.tar.gz"
