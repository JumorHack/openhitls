#!/usr/bin/env bash
#
# Experiment E4: same-machine comparison against the official optimised
# FrodoKEM (Microsoft PQCrypto-LWEKE) and liboqs, plus a source check that
# neither ships a NEON-vectorised CDF sampler (supports our "first" claim).
#
# This script clones and builds two EXTERNAL repos under e4_ext/.  External
# build systems drift, so each step is best-effort: a failure is reported but
# does not abort the rest.  Read the per-tool notes if a build fails.
#
# Outputs (results/):
#   e4_lweke_640aes.txt     PQCrypto-LWEKE FrodoKEM-640-AES KEM cycles
#   e4_liboqs_640aes.txt    liboqs FrodoKEM-640-AES speed_kem
#   e4_neon_sampler_grep.txt   source grep: any NEON sampler in either repo?
#   e4_versions.txt         commit hashes of both repos
#
# Prereqs: git, gcc, cmake, make/ninja, (optional) openssl-dev for liboqs.
# Run AFTER lib deps installed:  sudo apt-get install -y git cmake ninja-build libssl-dev
#
# Usage:  bash scripts/run_e4.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
mkdir -p results e4_ext
EXT="$REPO_ROOT/e4_ext"
PIN=""
if command -v taskset >/dev/null 2>&1; then PIN="taskset -c 0"; fi
JOBS=$(nproc 2>/dev/null || echo 4)

echo "################ E4: external baselines ################"
: > results/e4_versions.txt

# ---------------------------------------------------------------------------
# 1. Microsoft PQCrypto-LWEKE (the official optimised FrodoKEM)
# ---------------------------------------------------------------------------
build_lweke() {
    echo "===== PQCrypto-LWEKE ====="
    if [[ ! -d "$EXT/PQCrypto-LWEKE" ]]; then
        git clone --depth 1 https://github.com/microsoft/PQCrypto-LWEKE "$EXT/PQCrypto-LWEKE" \
            || { echo "  clone FAILED"; return 1; }
    fi
    cd "$EXT/PQCrypto-LWEKE"
    echo "PQCrypto-LWEKE $(git rev-parse --short HEAD)" >> "$REPO_ROOT/results/e4_versions.txt"
    # The FrodoKEM C reference/optimised lives at repo root with a Makefile.
    # ARCH=ARM64; AES via GENERATION_A=AES128; FAST opt where available.
    make clean >/dev/null 2>&1 || true
    if make ARCH=ARM64 GENERATION_A=AES128 OPT_LEVEL=FAST CC=gcc >/dev/null 2>"$REPO_ROOT/results/e4_lweke_build.log"; then
        :
    else
        echo "  OPT_LEVEL=FAST failed, retrying OPT_LEVEL=REFERENCE (see e4_lweke_build.log)"
        make clean >/dev/null 2>&1 || true
        make ARCH=ARM64 GENERATION_A=AES128 OPT_LEVEL=REFERENCE CC=gcc \
            >/dev/null 2>>"$REPO_ROOT/results/e4_lweke_build.log" \
            || { echo "  build FAILED -- inspect results/e4_lweke_build.log and the repo README"; cd "$REPO_ROOT"; return 1; }
    fi
    # Test/bench binary name varies by version: try the common ones.
    local bin=""
    for cand in frodo640/test_KEM ./test_KEM640 ./frodo640/test_KEM; do
        [[ -x "$cand" ]] && bin="$cand" && break
    done
    if [[ -z "$bin" ]]; then
        bin=$(find . -maxdepth 2 -name 'test_KEM*' -perm -u+x | head -1)
    fi
    if [[ -n "$bin" ]]; then
        echo "  running $bin"
        $PIN "$bin" > "$REPO_ROOT/results/e4_lweke_640aes.txt" 2>&1 || true
        echo "  saved: results/e4_lweke_640aes.txt"
    else
        echo "  no test_KEM binary found; list built binaries:"
        find . -maxdepth 2 -name 'test_*' -o -name '*bench*' 2>/dev/null | tee "$REPO_ROOT/results/e4_lweke_640aes.txt"
    fi
    cd "$REPO_ROOT"
}

# ---------------------------------------------------------------------------
# 2. liboqs
# ---------------------------------------------------------------------------
build_liboqs() {
    echo "===== liboqs ====="
    if [[ ! -d "$EXT/liboqs" ]]; then
        git clone --depth 1 https://github.com/open-quantum-safe/liboqs "$EXT/liboqs" \
            || { echo "  clone FAILED"; return 1; }
    fi
    cd "$EXT/liboqs"
    echo "liboqs $(git rev-parse --short HEAD)" >> "$REPO_ROOT/results/e4_versions.txt"
    cmake -S . -B build -DOQS_BUILD_ONLY_LIB=OFF -DOQS_USE_OPENSSL=OFF \
        >/dev/null 2>"$REPO_ROOT/results/e4_liboqs_build.log" \
        || { echo "  cmake FAILED -- see results/e4_liboqs_build.log"; cd "$REPO_ROOT"; return 1; }
    cmake --build build -j"$JOBS" >/dev/null 2>>"$REPO_ROOT/results/e4_liboqs_build.log" \
        || { echo "  build FAILED -- see results/e4_liboqs_build.log"; cd "$REPO_ROOT"; return 1; }
    local sk="build/tests/speed_kem"
    if [[ -x "$sk" ]]; then
        echo "  running $sk FrodoKEM-640-AES"
        $PIN "$sk" FrodoKEM-640-AES > "$REPO_ROOT/results/e4_liboqs_640aes.txt" 2>&1 \
            || $PIN "$sk" > "$REPO_ROOT/results/e4_liboqs_640aes.txt" 2>&1 || true
        echo "  saved: results/e4_liboqs_640aes.txt"
    else
        echo "  speed_kem not found at $sk"
    fi
    cd "$REPO_ROOT"
}

# ---------------------------------------------------------------------------
# 3. Source check: does either repo ship a NEON-vectorised CDF sampler?
# ---------------------------------------------------------------------------
grep_neon_sampler() {
    echo "===== NEON sampler source check ====="
    {
        echo "### Grep for NEON / SIMD sampling in FrodoKEM sources of both repos"
        echo "### (supports the paper's 'first NEON CDF sampler' claim)"
        echo
        for repo in "$EXT/PQCrypto-LWEKE" "$EXT/liboqs"; do
            [[ -d "$repo" ]] || continue
            echo "==== $repo ===="
            echo "-- files mentioning 'sample' under frodo dirs --"
            find "$repo" -ipath '*frodo*' \( -name '*.c' -o -name '*.h' -o -name '*.S' \) 2>/dev/null \
                | xargs grep -il "sample" 2>/dev/null || echo "(none)"
            echo "-- any NEON intrinsics/asm (vld1/vmul/cmgt/'arm_neon.h'/.8h) in frodo sample files --"
            find "$repo" -ipath '*frodo*' \( -name '*.c' -o -name '*.h' -o -name '*.S' \) 2>/dev/null \
                | xargs grep -lE "arm_neon\.h|vld1|vmulq|cmgt|\.8h|vget_" 2>/dev/null || echo "(none -> no NEON in frodo sources)"
            echo
        done
    } > results/e4_neon_sampler_grep.txt 2>&1
    echo "  saved: results/e4_neon_sampler_grep.txt"
    cat results/e4_neon_sampler_grep.txt
}

build_lweke      || echo "  [PQCrypto-LWEKE step incomplete]"
build_liboqs     || echo "  [liboqs step incomplete]"
grep_neon_sampler

echo
echo "################ E4 done ################"
echo "Collect: results/e4_lweke_640aes.txt  results/e4_liboqs_640aes.txt"
echo "         results/e4_neon_sampler_grep.txt  results/e4_versions.txt"
echo "(plus *_build.log if any build failed)"
echo
echo "Note: external build systems vary by version.  If a build fails, the"
echo "log tells you what; the openHiTLS-vs-reference numbers in the paper do"
echo "not depend on E4 -- it only adds a stronger baseline comparison."
