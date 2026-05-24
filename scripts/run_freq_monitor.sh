#!/usr/bin/env bash
#
# Experiment 6: CPU frequency stability during a benchmark run.
#
# Two paths:
#   (a) If /sys/.../cpufreq/scaling_cur_freq exists (bare metal / older
#       hypervisors), poll it every 500 ms while the benchmark runs.
#   (b) On EC2 Graviton 3 the cpufreq sysfs is hidden by the hypervisor,
#       so we instead let perf stat measure (cycles, task-clock) over the
#       full benchmark and compute effective frequency = cycles / task-clock.
#       This is the right number for the paper anyway: it reports the actual
#       average frequency the workload saw, not the nominal SKU number.
#
# Usage:
#   bash scripts/run_freq_monitor.sh -- ./build_neon/testcode/benchmark/openhitls_benchmark -a 'frodokem*' -t 1000
#
# Outputs (in results/):
#   * freq_log.csv             time_ms,cpu0[,cpu1...]_kHz             (only if path (a) works)
#   * freq_log_summary.txt     per-CPU min/max/mean/stdev/range%
#   * freq_perf.txt            perf-stat output (always written, path (b))
#   * freq_effective.txt       human-readable effective-frequency report

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
mkdir -p results

if [[ "${1:-}" != "--" ]]; then
    echo "Usage: bash $0 -- <benchmark command>" >&2
    exit 1
fi
shift
CMD=("$@")

LOG="results/freq_log.csv"
SUM="results/freq_log_summary.txt"
PERF="results/freq_perf.txt"
EFF="results/freq_effective.txt"

# --- detect path (a) ---
SYSFS_PATHS=()
for d in /sys/devices/system/cpu/cpu[0-9]*; do
    [[ -e "$d/cpufreq/scaling_cur_freq" ]] && SYSFS_PATHS+=("$d/cpufreq/scaling_cur_freq")
done
HAS_SYSFS_FREQ=${#SYSFS_PATHS[@]}

# --- path (b): perf stat wrapper (always do) ---
echo "[freq] running benchmark under perf stat..."
perf stat -e cycles:u,task-clock:u \
    "${CMD[@]}" > "${PERF}" 2>&1 || true

# extract:  cycles  /  task-clock(ms) → effective freq in MHz
{
    echo "=== Effective CPU frequency (from perf stat) ==="
    CYC=$(grep "cycles:u" "${PERF}" | awk '{print $1}' | tr -d ',')
    TMS=$(grep "task-clock:u" "${PERF}" | awk '{print $1}' | tr -d ',')
    if [[ -n "${CYC:-}" && -n "${TMS:-}" ]]; then
        # cycles / (task-clock ms * 1000) = MHz
        awk -v c="$CYC" -v t="$TMS" \
            'BEGIN { printf "cycles      : %s\n", c
                     printf "task-clock  : %s ms\n", t
                     printf "effective f : %.3f GHz (= cycles/task_clock)\n",
                            c / (t * 1e6) }'
    else
        echo "WARN: could not parse cycles/task-clock from $PERF"
    fi
    echo
    echo "Note on Graviton 3 (m7g): the hypervisor fixes the guest at the SKU's"
    echo "rated frequency (2.6 GHz for Neoverse V1).  An effective-frequency"
    echo "deviation < 1 percent indicates a stable, non-throttled run."
} > "${EFF}"
cat "${EFF}"

# --- path (a): cpufreq polling (only if sysfs visible) ---
if [[ ${HAS_SYSFS_FREQ} -gt 0 ]]; then
    echo
    echo "[freq] sysfs cpufreq present — also doing per-CPU polling..."

    CPUS=()
    for p in "${SYSFS_PATHS[@]}"; do
        CPUS+=("$(basename "$(dirname "$(dirname "$p")")")")
    done

    { printf "time_ms"; for c in "${CPUS[@]}"; do printf ",%s_kHz" "$c"; done; echo; } > "$LOG"

    "${CMD[@]}" > /dev/null 2>&1 &
    BPID=$!
    START=$(date +%s%3N)
    while kill -0 "$BPID" 2>/dev/null; do
        NOW=$(date +%s%3N)
        LINE="$((NOW - START))"
        for c in "${CPUS[@]}"; do
            f=$(cat "/sys/devices/system/cpu/$c/cpufreq/scaling_cur_freq" 2>/dev/null || echo "-1")
            LINE="$LINE,$f"
        done
        echo "$LINE" >> "$LOG"
        sleep 0.5
    done
    wait "$BPID" || true

    python3 - "$LOG" "$SUM" <<'PY'
import sys, csv, statistics
log, out = sys.argv[1], sys.argv[2]
with open(log) as f:
    rd = csv.reader(f); hdr = next(rd)
    cols = [[] for _ in hdr[1:]]
    for row in rd:
        for i, v in enumerate(row[1:]):
            try: cols[i].append(int(v))
            except ValueError: pass
with open(out, "w") as f:
    f.write("cpu, min_kHz, max_kHz, mean_kHz, stdev_kHz, range%\n")
    for name, samples in zip(hdr[1:], cols):
        if not samples:
            f.write(f"{name}, -, -, -, -, -\n"); continue
        mn, mx = min(samples), max(samples)
        avg = statistics.fmean(samples)
        sd  = statistics.pstdev(samples)
        rng = 100.0 * (mx - mn) / avg if avg else 0.0
        f.write(f"{name}, {mn}, {mx}, {avg:.0f}, {sd:.1f}, {rng:.2f}\n")
print("Summary:"); print(open(out).read())
PY
else
    echo "[freq] /sys/.../cpufreq not visible on this host — sysfs polling skipped."
    echo "  (Expected on EC2 m7g.  Use the effective-frequency number above.)"
    # Mark CSV explicitly as N/A
    echo "# sysfs cpufreq unavailable on this host (EC2 m7g hypervisor)" > "$LOG"
fi
