/*
 * This file is part of the openHiTLS project.
 *
 * openHiTLS is licensed under the Mulan PSL v2.
 *
 * frodokem_micro.c — Sub-function micro benchmark for FrodoKEM.
 *
 * Measures both wall-clock nanoseconds *and* CPU cycles (via the Linux
 * perf_event_open syscall, no `perf stat` wrapper needed) over N iterations
 * for the three NEON-optimised inner kernels:
 *   - FrodoCommonMulAddAsPlusEPortable  (AS + E)
 *   - FrodoCommonMulAddSaPlusEPortable  (S'A + E')
 *   - FrodoCommonSampleNFromR           (CDF sampling)
 *
 * Cycle reading uses the per-process PERF_COUNT_HW_CPU_CYCLES counter,
 * accessible from userspace on Linux when
 * /proc/sys/kernel/perf_event_paranoid <= 2 (the Ubuntu default).
 * If perf_event_open fails the program still reports nanoseconds.
 *
 * Run twice — once on a build with HITLS_CRYPTO_FRODOKEM_ARMV8=ON and once
 * with it OFF — and compute the speed-up ratio for the paper.
 */

#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <linux/perf_event.h>

#include "crypt_algid.h"
#include "crypt_errno.h"
#include "frodo_local.h"

/* The micro benchmark calls the sampler directly — it does NOT go through
 * frodokem_pke.c's dispatch.  So DISABLE_NEON_SAMPLE must be checked HERE,
 * not in the PKE file, for the ablation study to see the scalar version. */
#if defined(HITLS_CRYPTO_FRODOKEM_ARMV8) && !defined(DISABLE_NEON_SAMPLE)
extern void FrodoCommonSampleNFromR(uint16_t *samples, size_t n,
                                    const uint16_t *cdfTable, size_t cdfLen,
                                    const uint8_t *rBytes);
#define HAS_NEON_SAMPLER 1
#else
#define HAS_NEON_SAMPLER 0
static void SampleC_Ref(uint16_t *samples, size_t n,
                        const uint16_t *cdfTable, size_t cdfLen,
                        const uint8_t *rBytes)
{
    for (size_t i = 0; i < n; i++) {
        uint16_t r    = (uint16_t)rBytes[2 * i] | ((uint16_t)rBytes[2 * i + 1] << 8);
        uint16_t prnd = r >> 1;
        uint16_t sign = r & 1;
        uint16_t t    = 0;
        for (size_t j = 0; j < cdfLen - 1; j++) {
            t += (uint16_t)(cdfTable[j] - prnd) >> 15;
        }
        samples[i] = ((uint16_t)(-sign) ^ t) + sign;
    }
}
#endif

/* ---- Tunables (overridable via CLI: ./frodokem_micro <iters> [warmup]) ---- */
static int ITERS  = 10000;
static int WARMUP = 100;

/* ---- Cycle counter via perf_event_open ---- */
static int g_cycles_fd = -1;

static int open_cycles_counter(void)
{
    struct perf_event_attr pe;
    memset(&pe, 0, sizeof(pe));
    pe.type           = PERF_TYPE_HARDWARE;
    pe.size           = sizeof(pe);
    pe.config         = PERF_COUNT_HW_CPU_CYCLES;
    pe.disabled       = 1;             /* enable explicitly with ioctl */
    pe.exclude_kernel = 1;
    pe.exclude_hv     = 1;

    int fd = (int)syscall(SYS_perf_event_open, &pe, /*pid=*/0,
                          /*cpu=*/-1, /*group_fd=*/-1, /*flags=*/0);
    if (fd < 0) {
        fprintf(stderr, "perf_event_open(HW_CPU_CYCLES) failed: %s\n", strerror(errno));
        fprintf(stderr, "  Hint: ensure /proc/sys/kernel/perf_event_paranoid <= 2.\n");
        return -1;
    }
    if (ioctl(fd, PERF_EVENT_IOC_RESET, 0) < 0 ||
        ioctl(fd, PERF_EVENT_IOC_ENABLE, 0) < 0) {
        fprintf(stderr, "ioctl(perf_event) failed: %s\n", strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static inline uint64_t read_cycles(void)
{
    uint64_t v = 0;
    if (read(g_cycles_fd, &v, sizeof(v)) != (ssize_t)sizeof(v))
        return 0;
    return v;
}

static inline uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static int cmp_u64(const void *a, const void *b)
{
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}

static uint64_t median(uint64_t *arr, size_t n)
{
    qsort(arr, n, sizeof(uint64_t), cmp_u64);
    return arr[n / 2];
}

static double mean(const uint64_t *arr, size_t n)
{
    long double s = 0;
    for (size_t i = 0; i < n; i++) s += arr[i];
    return (double)(s / (long double)n);
}

static double stddev(const uint64_t *arr, size_t n, double mu)
{
    if (n < 2) return 0.0;
    long double sq = 0;
    for (size_t i = 0; i < n; i++) {
        long double d = (long double)arr[i] - (long double)mu;
        sq += d * d;
    }
    /* sample stddev (Bessel's correction) */
    return (double)sqrtl(sq / (long double)(n - 1));
}

static uint64_t arrmin(const uint64_t *arr, size_t n)
{
    uint64_t m = arr[0];
    for (size_t i = 1; i < n; i++) if (arr[i] < m) m = arr[i];
    return m;
}
static uint64_t arrmax(const uint64_t *arr, size_t n)
{
    uint64_t m = arr[0];
    for (size_t i = 1; i < n; i++) if (arr[i] > m) m = arr[i];
    return m;
}

static void rand_fill(uint8_t *p, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        p[i] = (uint8_t)(rand() & 0xff);
    }
}

/* ------------------------------------------------------------------ */
/* Per-iteration measurement helpers                                    */
/* ------------------------------------------------------------------ */

typedef struct {
    uint64_t med_cycles, med_ns;
    uint64_t min_cycles, max_cycles;
    uint64_t min_ns,     max_ns;
    double   mean_cycles, mean_ns;
    double   sd_cycles,   sd_ns;
} BenchResult;

#define MEASURE(stmt, out)                                                  \
    do {                                                                    \
        uint64_t *cyc = malloc(ITERS * sizeof(uint64_t));                   \
        uint64_t *nss = malloc(ITERS * sizeof(uint64_t));                   \
        for (int _w = 0; _w < WARMUP; _w++) { stmt; }                       \
        for (int _i = 0; _i < ITERS; _i++) {                                \
            uint64_t c0 = read_cycles();                                    \
            uint64_t t0 = now_ns();                                         \
            stmt;                                                           \
            uint64_t t1 = now_ns();                                         \
            uint64_t c1 = read_cycles();                                    \
            cyc[_i] = c1 - c0;                                              \
            nss[_i] = t1 - t0;                                              \
        }                                                                   \
        (out).mean_cycles = mean(cyc, ITERS);                               \
        (out).mean_ns     = mean(nss, ITERS);                               \
        (out).sd_cycles   = stddev(cyc, ITERS, (out).mean_cycles);          \
        (out).sd_ns       = stddev(nss, ITERS, (out).mean_ns);              \
        (out).min_cycles  = arrmin(cyc, ITERS);                             \
        (out).max_cycles  = arrmax(cyc, ITERS);                             \
        (out).min_ns      = arrmin(nss, ITERS);                             \
        (out).max_ns      = arrmax(nss, ITERS);                             \
        /* median() sorts in place, so run last */                          \
        (out).med_cycles  = median(cyc, ITERS);                             \
        (out).med_ns      = median(nss, ITERS);                             \
        free(cyc); free(nss);                                               \
    } while (0)

/* ------------------------------------------------------------------ */
/* Benchmarks                                                          */
/* ------------------------------------------------------------------ */

static BenchResult bench_sample(const FrodoKemParams *p)
{
    size_t count = (size_t)p->n * p->nBar;
    uint16_t *out  = malloc(count * sizeof(uint16_t));
    uint8_t  *rbuf = malloc(count * 2);
    rand_fill(rbuf, count * 2);

    BenchResult r;
#if HAS_NEON_SAMPLER
    MEASURE(FrodoCommonSampleNFromR(out, count, p->cdfTable, p->cdfLen, rbuf), r);
#else
    MEASURE(SampleC_Ref(out, count, p->cdfTable, p->cdfLen, rbuf), r);
#endif
    free(out); free(rbuf);
    return r;
}

static BenchResult bench_matmul_as(const FrodoKemParams *p)
{
    size_t count = (size_t)p->n * p->nBar;
    uint16_t *out = calloc(count, sizeof(uint16_t));
    uint16_t *mat = malloc(count * sizeof(uint16_t));
    uint8_t   seedA[16];
    rand_fill(seedA, sizeof(seedA));
    rand_fill((uint8_t *)mat, count * sizeof(uint16_t));

    BenchResult r;
    /* No need to memset between iterations: the function is a MLA
     * accumulator (uint16_t wraps mod 2^16) so the amount of work is
     * identical regardless of starting values. */
    MEASURE(FrodoCommonMulAddAsPlusEPortable(out, mat, seedA, p), r);
    free(out); free(mat);
    return r;
}

static BenchResult bench_matmul_sa(const FrodoKemParams *p)
{
    size_t count = (size_t)p->n * p->nBar;
    uint16_t *out = calloc(count, sizeof(uint16_t));
    uint16_t *s_  = malloc(count * sizeof(uint16_t));
    uint16_t *e_  = malloc(count * sizeof(uint16_t));
    uint8_t   seedA[16];
    rand_fill(seedA, sizeof(seedA));
    rand_fill((uint8_t *)s_, count * sizeof(uint16_t));
    rand_fill((uint8_t *)e_, count * sizeof(uint16_t));

    BenchResult r;
    MEASURE(FrodoCommonMulAddSaPlusEPortable(out, s_, e_, seedA, p), r);
    free(out); free(s_); free(e_);
    return r;
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */

static const int g_paraIds[] = {
    CRYPT_KEM_TYPE_FRODOKEM_640_AES,
    CRYPT_KEM_TYPE_FRODOKEM_976_AES,
    CRYPT_KEM_TYPE_FRODOKEM_1344_AES,
    CRYPT_KEM_TYPE_FRODOKEM_640_SHAKE,
    CRYPT_KEM_TYPE_FRODOKEM_976_SHAKE,
    CRYPT_KEM_TYPE_FRODOKEM_1344_SHAKE,
};
static const char *g_paraNames[] = {
    "frodo-640-aes",   "frodo-976-aes",   "frodo-1344-aes",
    "frodo-640-shake", "frodo-976-shake", "frodo-1344-shake",
};
#define NPARA  (sizeof(g_paraIds) / sizeof(g_paraIds[0]))

static void print_row(const char *name, BenchResult as, BenchResult sa, BenchResult sm)
{
    printf("%-18s  %12lu / %-10.0f  %12lu / %-10.0f  %12lu / %-10.0f\n",
           name,
           (unsigned long)as.med_cycles, as.mean_cycles,
           (unsigned long)sa.med_cycles, sa.mean_cycles,
           (unsigned long)sm.med_cycles, sm.mean_cycles);
}

static void print_stats_block(const char *title, const char *paraName, BenchResult r)
{
    /* CV% = relative stddev = sd / mean × 100, a single-number measure
     * of how stable the measurement is.  <1% is considered very stable. */
    double cv = (r.mean_cycles > 0.0) ? (100.0 * r.sd_cycles / r.mean_cycles) : 0.0;
    printf("  %-12s  %-18s  median=%-12lu  mean=%-12.0f  stddev=%-10.0f  cv%%=%-6.2f  "
           "min=%-12lu  max=%-12lu\n",
           title, paraName,
           (unsigned long)r.med_cycles, r.mean_cycles, r.sd_cycles, cv,
           (unsigned long)r.min_cycles, (unsigned long)r.max_cycles);
}

/* Quick environment dump: CPU model, current freq, governor, cache.
 * No external tools, just /proc and /sys reads. */
static void print_env(void)
{
    printf("===== Environment =====\n");

    /* CPU model */
    FILE *fp = fopen("/proc/cpuinfo", "r");
    if (fp) {
        char line[512];
        int seen_model = 0, seen_features = 0;
        while (fgets(line, sizeof(line), fp)) {
            if (!seen_model && strncmp(line, "CPU implementer", 15) == 0) {
                fputs(line, stdout); seen_model = 1;
            }
            if (!seen_features && strncmp(line, "Features", 8) == 0) {
                fputs(line, stdout); seen_features = 1;
            }
            if (seen_model && seen_features) break;
        }
        fclose(fp);
    }

    /* CPU frequency (kHz) */
    fp = fopen("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", "r");
    if (fp) {
        unsigned long khz = 0;
        if (fscanf(fp, "%lu", &khz) == 1)
            printf("cpu0 freq      : %lu kHz (%.3f GHz)\n", khz, khz / 1000000.0);
        fclose(fp);
    } else {
        printf("cpu0 freq      : (scaling_cur_freq unavailable)\n");
    }

    /* Governor */
    fp = fopen("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", "r");
    if (fp) {
        char gov[64] = {0};
        if (fgets(gov, sizeof(gov), fp))
            printf("cpu0 governor  : %s", gov);
        fclose(fp);
    }

    printf("=========================\n\n");
}

int main(int argc, char **argv)
{
    srand(0xC0FFEE);

    if (argc >= 2) ITERS  = atoi(argv[1]);
    if (argc >= 3) WARMUP = atoi(argv[2]);
    if (ITERS <= 0)  ITERS  = 10000;
    if (WARMUP < 0)  WARMUP = 100;

#if defined(HITLS_CRYPTO_FRODOKEM_ARMV8)
    printf("Build: NEON optimised  (HITLS_CRYPTO_FRODOKEM_ARMV8=1)\n");
#else
    printf("Build: C reference     (HITLS_CRYPTO_FRODOKEM_ARMV8=0)\n");
#endif
#if defined(FRODO_NAIVE_SCHEDULE)
    printf("Schedule: row-at-a-time (config E, FRODO_NAIVE_SCHEDULE=1)\n");
#elif defined(FRODO_RR_SCHEDULE)
    printf("Schedule: round-robin (config B, FRODO_RR_SCHEDULE=1)\n");
#else
    printf("Schedule: diagonal MLA / Latin-square (config C, default)\n");
#endif
    printf("Sampler : %s\n",
           HAS_NEON_SAMPLER ? "NEON FrodoCommonSampleNFromR (asm)"
                            : "scalar SampleC_Ref (DISABLE_NEON_SAMPLE or no NEON)");
    printf("Iterations: warmup=%d  measured=%d\n\n", WARMUP, ITERS);

    print_env();

    g_cycles_fd = open_cycles_counter();
    if (g_cycles_fd < 0) {
        fprintf(stderr, "WARNING: continuing without cycle counts (will report 0).\n\n");
    }

    printf("=== Cycles per call (median / mean) ===\n");
    printf("%-18s  %25s  %25s  %25s\n",
           "parameter set",
           "AS+E",
           "S'A+E'",
           "SampleNFromR");
    printf("%-18s  %25s  %25s  %25s\n",
           "-------------",
           "-------------------------",
           "-------------------------",
           "-------------------------");

    BenchResult as_r[NPARA], sa_r[NPARA], sm_r[NPARA];

    for (size_t i = 0; i < NPARA; i++) {
        const FrodoKemParams *p = FrodoGetParamsById(g_paraIds[i]);
        if (p == NULL) {
            fprintf(stderr, "FrodoGetParamsById(%d) returned NULL\n", g_paraIds[i]);
            continue;
        }
        as_r[i] = bench_matmul_as(p);
        sa_r[i] = bench_matmul_sa(p);
        sm_r[i] = bench_sample(p);
        print_row(g_paraNames[i], as_r[i], sa_r[i], sm_r[i]);
        fflush(stdout);
    }

    printf("\n=== Nanoseconds per call (median) ===\n");
    printf("%-18s  %12s  %12s  %12s\n",
           "parameter set", "AS+E (ns)", "S'A+E' (ns)", "Sample (ns)");
    printf("%-18s  %12s  %12s  %12s\n",
           "-------------", "----------", "-----------", "-----------");
    for (size_t i = 0; i < NPARA; i++) {
        printf("%-18s  %12lu  %12lu  %12lu\n",
               g_paraNames[i],
               (unsigned long)as_r[i].med_ns,
               (unsigned long)sa_r[i].med_ns,
               (unsigned long)sm_r[i].med_ns);
    }

    /* Full per-call statistics (median / mean / stddev / cv% / min / max).
     * Useful for the paper's stability discussion. */
    printf("\n=== Per-call cycle statistics (full) ===\n");
    for (size_t i = 0; i < NPARA; i++) {
        print_stats_block("AS+E",         g_paraNames[i], as_r[i]);
        print_stats_block("S'A+E'",       g_paraNames[i], sa_r[i]);
        print_stats_block("SampleNFromR", g_paraNames[i], sm_r[i]);
        printf("\n");
    }

    if (g_cycles_fd >= 0)
        close(g_cycles_fd);
    printf("Done.\n");
    return 0;
}
