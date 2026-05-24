#!/usr/bin/env bash
#
# Environment dump for the paper's Experimental Setup section.
# Run on the Graviton 3 instance once before/after the experiments.
#
# Usage: bash scripts/collect_env.sh > results/environment.txt

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "===== date ====="
date -u +"%Y-%m-%dT%H:%M:%SZ"
echo "hostname: $(hostname)"

echo
echo "===== EC2 instance metadata (best-effort) ====="
curl -sm 2 http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null && echo \
    || echo "(IMDS unavailable; running outside EC2?)"

echo
echo "===== uname ====="
uname -a

echo
echo "===== /etc/os-release ====="
cat /etc/os-release 2>/dev/null || true

echo
echo "===== lscpu ====="
lscpu

echo
echo "===== /proc/cpuinfo (first CPU only) ====="
awk '/^$/{exit} {print}' /proc/cpuinfo

echo
echo "===== CPU frequency / governor ====="
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    n=$(basename "$cpu")
    f=$(cat "$cpu/cpufreq/scaling_cur_freq" 2>/dev/null || echo "?")
    g=$(cat "$cpu/cpufreq/scaling_governor" 2>/dev/null || echo "?")
    echo "$n: cur=${f} kHz governor=${g}"
done

echo
echo "===== /proc/meminfo (top) ====="
head -5 /proc/meminfo

echo
echo "===== compiler ====="
gcc --version | head -1
gcc -dumpmachine
echo "as --version: $(as --version | head -1)"
echo "ld --version: $(ld --version | head -1)"

echo
echo "===== openHiTLS commit ====="
git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "(not a git repo)"
git -C "$REPO_ROOT" log -1 --format="%H  %s  (%ci)" 2>/dev/null || true
echo "branch: $(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"

echo
echo "===== perf_event_paranoid ====="
cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "?"
