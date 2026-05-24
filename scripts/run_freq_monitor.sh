#!/usr/bin/env bash
#
# Experiment 6: CPU frequency stability monitoring during a benchmark run.
#
# Polls /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq every 500 ms
# while a benchmark process is running, writing each sample to a log.
#
# Usage:
#   bash scripts/run_freq_monitor.sh -- ./build_neon/testcode/benchmark/openhitls_benchmark -a 'frodokem*' -t 1000
#
# Output:
#   results/freq_log.csv        time_ms,cpu0,cpu1,cpu2,cpu3
#   results/freq_log_summary.txt

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
mkdir -p results

LOG="results/freq_log.csv"
SUM="results/freq_log_summary.txt"

if [[ "${1:-}" != "--" ]]; then
    echo "Usage: bash $0 -- <benchmark command>" >&2
    exit 1
fi
shift
CMD=("$@")

# Detect CPUs
CPUS=()
for d in /sys/devices/system/cpu/cpu[0-9]*; do
    [[ -e "$d/cpufreq/scaling_cur_freq" ]] && CPUS+=("$(basename "$d")")
done
NCPU=${#CPUS[@]}
echo "Monitoring ${NCPU} cpus: ${CPUS[*]}"

# Header
{ printf "time_ms"; for c in "${CPUS[@]}"; do printf ",%s_kHz" "$c"; done; echo; } > "$LOG"

# Start benchmark in background
echo "Launching benchmark: ${CMD[*]}"
"${CMD[@]}" > results/freq_bench_stdout.txt 2>&1 &
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
echo "Done. Samples:"
wc -l "$LOG"

# Quick statistics with awk
python3 - "$LOG" "$SUM" <<'PY'
import sys, csv, statistics
log, out = sys.argv[1], sys.argv[2]
with open(log) as f:
    rd = csv.reader(f)
    hdr = next(rd)
    cols = [[] for _ in hdr[1:]]
    for row in rd:
        for i, v in enumerate(row[1:]):
            try:
                cols[i].append(int(v))
            except ValueError:
                pass
with open(out, "w") as f:
    f.write("cpu, min_kHz, max_kHz, mean_kHz, stdev_kHz, range%\n")
    for name, samples in zip(hdr[1:], cols):
        if not samples:
            f.write(f"{name}, -, -, -, -, -\n")
            continue
        mn, mx = min(samples), max(samples)
        avg = statistics.fmean(samples)
        sd  = statistics.pstdev(samples)
        rng = 100.0 * (mx - mn) / avg if avg else 0.0
        f.write(f"{name}, {mn}, {mx}, {avg:.0f}, {sd:.1f}, {rng:.2f}\n")
print("Summary written:")
with open(out) as f: print(f.read())
PY
