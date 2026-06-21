# FrodoKEM benchmark scripts

Helper scripts for the TCHES paper's experimental section.  All paths are
relative to the openHiTLS repo root.

## Quick start

```bash
# One-off: dump environment for the paper's Experimental Setup
bash scripts/collect_env.sh > results/environment.txt

# Main 4-config ablation (Experiment 1).  Default 1000 / 100 iterations.
bash scripts/run_ablation.sh

# E1a: three-way MLA schedule comparison on one core (Experiment 1a).
# Builds row-at-a-time / round-robin / diagonal and runs AS+E for each.
bash scripts/run_e1a.sh

# Compiler optimisation sweep -O0 / -O2 / -O3 (Experiment 4)
bash scripts/run_optlevel.sh

# Cache-behaviour comparison NEON vs C-ref (Experiment 5)
# (requires existing build_neon/ and build_ref/)
bash scripts/run_cache.sh

# CPU frequency sampling during a long benchmark (Experiment 6)
bash scripts/run_freq_monitor.sh -- \
    ./build_neon/testcode/benchmark/openhitls_benchmark -a 'frodokem*' -t 1000
```

Override iterations via env:

```bash
ITERS_NEON=5000 ITERS_REF=200 bash scripts/run_ablation.sh
```

## Files produced (all under `results/`)

| File | Source | Purpose |
|------|--------|---------|
| `ablation_A_baseline_c.txt` | run_ablation.sh | Config (A) AS+E cycles |
| `ablation_B_neon_naive.txt` | run_ablation.sh | Config (B) AS+E cycles |
| `ablation_C_neon_diag.txt`  | run_ablation.sh | Config (C) AS+E cycles |
| `ablation_D_neon_full.txt`  | run_ablation.sh | Config (D) AS+E cycles |
| `ablation_D_kem.txt`        | run_ablation.sh | Config (D) full KEM E2E |
| `opt_{O0,O2,O3}_{ref,neon}.txt` | run_optlevel.sh | Per -O level numbers |
| `cache_{neon,ref}.txt`      | run_cache.sh    | L1d / LLC counters |
| `freq_log.csv` + `freq_log_summary.txt` | run_freq_monitor.sh | CPU frequency timeline |
| `environment.txt`           | collect_env.sh  | Platform / toolchain metadata |

## Ablation macro switches

| Macro | Effect |
|-------|--------|
| `FRODO_NAIVE_SCHEDULE` | Use `MultAsPlusEAES_naive` — the **row-at-a-time** schedule (config E), each accumulator written four times back-to-back. |
| `FRODO_RR_SCHEDULE`    | Use `MultAsPlusEAES_rr` — the **round-robin** schedule (config B), accumulator rotated every instruction. |
| `DISABLE_NEON_SAMPLE`  | Force the scalar C reference `FrodoCommonSampleNFromR` even when `HITLS_CRYPTO_FRODOKEM_ARMV8=ON`. |

The default (neither schedule macro) is the **diagonal / Latin-square**
schedule (config C).  At most one schedule macro may be set.
Pass them as CMake options (`-DFRODO_RR_SCHEDULE=ON`), which propagate via
`target_compile_definitions` to both the FrodoKEM library and the
`frodokem_micro` binary's diagnostic header.
