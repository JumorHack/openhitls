#!/usr/bin/env bash
#
# Experiment E2: PRG / MAC decomposition of the matrix routines.
#
# The AS+E and S'A+E' functions generate A on the fly (AES/SHAKE) AND do the
# multiply-accumulate (MAC) in one interleaved loop, so the "AS+E" cycle
# counts in the main results include Gen(A).  This experiment separates them:
#
#   FULL      = Gen(A) + MAC      (normal build)
#   GEN-ONLY  = Gen(A)            (build with -DFRODO_BENCH_GEN_ONLY=ON,
#                                  which skips the MAC call -- benchmark only)
#   MAC       = FULL - GEN-ONLY   (derived)
#
# Done for both the C reference and the NEON build, so the *pure-MAC* speedup
# (MAC_ref / MAC_neon) can be reported -- it is higher than the FULL ratio,
# which the PRG share dilutes.
#
# Builds (all -O2, the production setting; ablation sampler is irrelevant here
# but kept scalar so the AS+E figure is comparable to the main ablation):
#   build_e2_ref_full   build_e2_ref_gen
#   build_e2_neon_full  build_e2_neon_gen
#
# Usage:   bash scripts/run_e2.sh            # build + run all four
#          bash scripts/run_e2.sh build      # build only
#          bash scripts/run_e2.sh run        # run existing builds
# Env:     ITERS_NEON (default 2000)  ITERS_REF (default 200)

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ITERS_NEON=${ITERS_NEON:-2000}
ITERS_REF=${ITERS_REF:-200}
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
COMMON_FLAGS="-O2 -march=armv8.4-a+crypto+sha3"

PIN=""
if command -v taskset >/dev/null 2>&1; then PIN="taskset -c 0"; fi

build_one()
{
    local tag="$1"; shift
    local dir="build_e2_${tag}"
    echo "===== Build [$tag] ($dir) ====="
    rm -rf "$dir"; mkdir -p "$dir" && cd "$dir"
    cmake \
        -DHITLS_BUILD_BENCHMARK=ON \
        -DHITLS_CRYPTO_FRODOKEM=ON \
        -DCMAKE_C_FLAGS="${COMMON_FLAGS}" \
        "$@" \
        ..
    make -j"$JOBS" frodokem_micro
    cd ..
}

run_one()
{
    local tag="$1"; local iters="$2"
    local dir="build_e2_${tag}"
    local out="results/e2_${tag}.txt"
    mkdir -p results
    echo "===== Run [$tag] iters=$iters ====="
    $PIN ./"$dir"/testcode/benchmark/frodokem_micro "$iters" > "$out"
    echo "  saved: $out"
    head -7 "$out"      # header incl. "Measure : FULL / GEN-ONLY"
    echo
}

NEON_FLAGS=(-DHITLS_ASM_ARMV8=ON -DHITLS_CRYPTO_FRODOKEM_ASM=ON -DHITLS_CRYPTO_FRODOKEM_ARMV8=ON)

if [[ "${1:-all}" == "all" || "${1:-all}" == "build" ]]; then
    build_one ref_full                                          # C ref, Gen+MAC
    build_one ref_gen                  -DFRODO_BENCH_GEN_ONLY=ON # C ref, Gen only
    build_one neon_full "${NEON_FLAGS[@]}"                       # NEON, Gen+MAC
    build_one neon_gen  "${NEON_FLAGS[@]}" -DFRODO_BENCH_GEN_ONLY=ON  # NEON, Gen only
fi

if [[ "${1:-all}" == "all" || "${1:-all}" == "run" ]]; then
    run_one ref_full  "$ITERS_REF"
    run_one ref_gen   "$ITERS_REF"
    run_one neon_full "$ITERS_NEON"
    run_one neon_gen  "$ITERS_NEON"

    # ---- derive MAC = FULL - GEN for AS+E, per parameter set ----
    echo "===== AS+E decomposition (median cycles; MAC = FULL - GEN) ====="
    printf "%-18s %14s %14s %14s | %14s %14s %14s | %8s\n" \
        "param" "ref_full" "ref_gen" "ref_MAC" "neon_full" "neon_gen" "neon_MAC" "MACspeedup"
    for p in frodo-640-aes frodo-976-aes frodo-1344-aes \
             frodo-640-shake frodo-976-shake frodo-1344-shake; do
        rf=$(grep "^$p " results/e2_ref_full.txt  | head -1 | awk '{print $2}')
        rg=$(grep "^$p " results/e2_ref_gen.txt   | head -1 | awk '{print $2}')
        nf=$(grep "^$p " results/e2_neon_full.txt | head -1 | awk '{print $2}')
        ng=$(grep "^$p " results/e2_neon_gen.txt  | head -1 | awk '{print $2}')
        # the AS+E column is the first numeric column ("median / mean" -> $2 is median)
        awk -v p="$p" -v rf="$rf" -v rg="$rg" -v nf="$nf" -v ng="$ng" 'BEGIN{
            rmac = rf - rg; nmac = nf - ng;
            sp = (nmac>0)? rmac/nmac : 0;
            printf "%-18s %14s %14s %14d | %14s %14s %14d | %7.2fx\n",
                   p, rf, rg, rmac, nf, ng, nmac, sp;
        }'
    done
    echo
    echo "NOTE: the AS+E column parsed above is the median (first number)."
    echo "If the columns look wrong, check the '=== Cycles per call' table in the txt files."
fi
