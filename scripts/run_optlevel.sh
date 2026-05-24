#!/usr/bin/env bash
#
# Experiment 4: Compiler optimization level study (-O0 / -O2 / -O3).
#
# Rebuilds C-reference and NEON variants under each -O level and
# records the AS+E cycle count from frodokem_micro for Frodo-640-AES.
#
# Usage: bash scripts/run_optlevel.sh

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

mkdir -p results
JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
ITERS_NEON=${ITERS_NEON:-1000}
ITERS_REF=${ITERS_REF:-100}
ARCH_FLAGS="-march=armv8.4-a+crypto+sha3"

rebuild()
{
    local dir="$1"; shift
    local opt="$1"; shift
    rm -rf "$dir"
    mkdir -p "$dir" && cd "$dir"
    cmake \
        -DHITLS_BUILD_BENCHMARK=ON \
        -DHITLS_CRYPTO_FRODOKEM=ON \
        -DCMAKE_C_FLAGS="${opt} ${ARCH_FLAGS}" \
        "$@" \
        ..
    make -j"$JOBS" frodokem_micro
    cd ..
}

for OPT in O0 O2 O3; do
    OPT_FLAG="-${OPT}"
    echo "===== Optimisation level ${OPT_FLAG} ====="

    # C reference
    rebuild "build_opt_${OPT}_ref" "$OPT_FLAG"
    ./build_opt_${OPT}_ref/testcode/benchmark/frodokem_micro "$ITERS_REF" \
        > "results/opt_${OPT}_ref.txt"

    # NEON
    rebuild "build_opt_${OPT}_neon" "$OPT_FLAG" \
        -DHITLS_ASM_ARMV8=ON \
        -DHITLS_CRYPTO_FRODOKEM_ASM=ON \
        -DHITLS_CRYPTO_FRODOKEM_ARMV8=ON
    ./build_opt_${OPT}_neon/testcode/benchmark/frodokem_micro "$ITERS_NEON" \
        > "results/opt_${OPT}_neon.txt"
done

echo
echo "Done. Outputs:"
ls -l results/opt_*.txt
echo
echo "Summary (median AS+E cycles for frodo-640-aes):"
printf "%-6s  %15s  %15s  %8s\n" "OPT" "C-ref cycles" "NEON cycles" "speedup"
for OPT in O0 O2 O3; do
    REF=$(grep "frodo-640-aes" "results/opt_${OPT}_ref.txt" | head -1 | awk '{print $3}')
    NEON=$(grep "frodo-640-aes" "results/opt_${OPT}_neon.txt" | head -1 | awk '{print $3}')
    if [[ -n "$REF" && -n "$NEON" && "$NEON" != "0" ]]; then
        SP=$(awk "BEGIN { printf \"%.2fx\", $REF / $NEON }")
    else
        SP="?"
    fi
    printf "%-6s  %15s  %15s  %8s\n" "-${OPT}" "${REF:-?}" "${NEON:-?}" "$SP"
done
