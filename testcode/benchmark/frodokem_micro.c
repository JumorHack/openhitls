/*
 * This file is part of the openHiTLS project.
 *
 * openHiTLS is licensed under the Mulan PSL v2.
 *
 * frodokem_micro.c — Sub-function micro benchmark for FrodoKEM.
 *
 * Measures median latency (ns) over N iterations for the three NEON-optimised
 * inner kernels:
 *   - FrodoCommonMulAddAsPlusEPortable  (AS + E)
 *   - FrodoCommonMulAddSaPlusEPortable  (S'A + E')
 *   - FrodoCommonSampleNFromR           (CDF sampling)
 *
 * Run twice — once on a build with HITLS_CRYPTO_FRODOKEM_ARMV8=ON and once
 * with it OFF — and compute the speed-up ratio for the paper.
 *
 * For exact CPU cycles wrap with:
 *   perf stat -e cycles,instructions ./frodokem_micro
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>
#include <time.h>

#include "crypt_algid.h"
#include "crypt_errno.h"
#include "frodo_local.h"

/* ------------------------------------------------------------------ */
/* Reference C sampler — kept locally because the version in           */
/* frodokem_pke.c is `static` and not visible to this translation unit */
/* in the non-NEON build.                                              */
/* ------------------------------------------------------------------ */
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

#if defined(HITLS_CRYPTO_FRODOKEM_ARMV8)
/* NEON build: assembly exposes the optimised symbol globally. */
extern void FrodoCommonSampleNFromR(uint16_t *samples, size_t n,
                                    const uint16_t *cdfTable, size_t cdfLen,
                                    const uint8_t *rBytes);
#define HAS_NEON_SAMPLER 1
#else
#define HAS_NEON_SAMPLER 0
#endif

/* ---- Tunables ---- */
#define ITERS  10000
#define WARMUP 100

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

static uint64_t median_ns(uint64_t *arr, size_t n)
{
    qsort(arr, n, sizeof(uint64_t), cmp_u64);
    return arr[n / 2];
}

static void rand_fill(uint8_t *p, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        p[i] = (uint8_t)(rand() & 0xff);
    }
}

/* ------------------------------------------------------------------ */
/* Benchmarks                                                          */
/* ------------------------------------------------------------------ */

static uint64_t bench_sample_active(const FrodoKemParams *p)
{
    size_t count = (size_t)p->n * p->nBar;
    uint16_t *out  = malloc(count * sizeof(uint16_t));
    uint8_t  *rbuf = malloc(count * 2);
    rand_fill(rbuf, count * 2);

    /* Active sampler: NEON if available, otherwise the local C reference. */
#if HAS_NEON_SAMPLER
    for (int i = 0; i < WARMUP; i++)
        FrodoCommonSampleNFromR(out, count, p->cdfTable, p->cdfLen, rbuf);
#else
    for (int i = 0; i < WARMUP; i++)
        SampleC_Ref(out, count, p->cdfTable, p->cdfLen, rbuf);
#endif

    uint64_t *t = malloc(ITERS * sizeof(uint64_t));
    for (int i = 0; i < ITERS; i++) {
        uint64_t s = now_ns();
#if HAS_NEON_SAMPLER
        FrodoCommonSampleNFromR(out, count, p->cdfTable, p->cdfLen, rbuf);
#else
        SampleC_Ref(out, count, p->cdfTable, p->cdfLen, rbuf);
#endif
        t[i] = now_ns() - s;
    }
    uint64_t med = median_ns(t, ITERS);
    free(out); free(rbuf); free(t);
    return med;
}

static uint64_t bench_matmul_as(const FrodoKemParams *p)
{
    size_t count = (size_t)p->n * p->nBar;
    uint16_t *out  = calloc(count, sizeof(uint16_t));
    uint16_t *mat  = malloc(count * sizeof(uint16_t));
    uint8_t   seedA[16];
    rand_fill(seedA, sizeof(seedA));
    rand_fill((uint8_t *)mat, count * sizeof(uint16_t));

    for (int i = 0; i < WARMUP; i++) {
        memset(out, 0, count * sizeof(uint16_t));
        FrodoCommonMulAddAsPlusEPortable(out, mat, seedA, p);
    }

    uint64_t *t = malloc(ITERS * sizeof(uint64_t));
    for (int i = 0; i < ITERS; i++) {
        memset(out, 0, count * sizeof(uint16_t));
        uint64_t s = now_ns();
        FrodoCommonMulAddAsPlusEPortable(out, mat, seedA, p);
        t[i] = now_ns() - s;
    }
    uint64_t med = median_ns(t, ITERS);
    free(out); free(mat); free(t);
    return med;
}

static uint64_t bench_matmul_sa(const FrodoKemParams *p)
{
    size_t count = (size_t)p->n * p->nBar;
    uint16_t *out = calloc(count, sizeof(uint16_t));
    uint16_t *s_  = malloc(count * sizeof(uint16_t));
    uint16_t *e_  = malloc(count * sizeof(uint16_t));
    uint8_t   seedA[16];
    rand_fill(seedA, sizeof(seedA));
    rand_fill((uint8_t *)s_, count * sizeof(uint16_t));
    rand_fill((uint8_t *)e_, count * sizeof(uint16_t));

    for (int i = 0; i < WARMUP; i++)
        FrodoCommonMulAddSaPlusEPortable(out, s_, e_, seedA, p);

    uint64_t *t = malloc(ITERS * sizeof(uint64_t));
    for (int i = 0; i < ITERS; i++) {
        uint64_t st = now_ns();
        FrodoCommonMulAddSaPlusEPortable(out, s_, e_, seedA, p);
        t[i] = now_ns() - st;
    }
    uint64_t med = median_ns(t, ITERS);
    free(out); free(s_); free(e_); free(t);
    return med;
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
    "frodo-640-aes",
    "frodo-976-aes",
    "frodo-1344-aes",
    "frodo-640-shake",
    "frodo-976-shake",
    "frodo-1344-shake",
};

#define NPARA  (sizeof(g_paraIds) / sizeof(g_paraIds[0]))

int main(void)
{
    srand(0xC0FFEE);

#if defined(HITLS_CRYPTO_FRODOKEM_ARMV8)
    printf("Build: NEON optimised  (HITLS_CRYPTO_FRODOKEM_ARMV8=1)\n");
#else
    printf("Build: C reference     (HITLS_CRYPTO_FRODOKEM_ARMV8=0)\n");
#endif
    printf("Iterations: warmup=%d  measured=%d  (reporting median ns)\n", WARMUP, ITERS);
    printf("Tip: wrap with `perf stat -e cycles` for hardware cycles.\n\n");

    printf("%-20s  %14s  %14s  %14s\n",
           "parameter set", "AS+E (ns)", "S'A+E' (ns)", "SampleNFromR (ns)");
    printf("%-20s  %14s  %14s  %14s\n",
           "-------------", "----------", "-----------", "-----------------");

    for (size_t i = 0; i < NPARA; i++) {
        const FrodoKemParams *p = FrodoGetParamsById(g_paraIds[i]);
        if (p == NULL) {
            fprintf(stderr, "FrodoGetParamsById(%d) returned NULL\n", g_paraIds[i]);
            continue;
        }
        uint64_t a  = bench_matmul_as(p);
        uint64_t b  = bench_matmul_sa(p);
        uint64_t c  = bench_sample_active(p);
        printf("%-20s  %14lu  %14lu  %14lu\n",
               g_paraNames[i], (unsigned long)a, (unsigned long)b, (unsigned long)c);
        fflush(stdout);
    }

    printf("\nDone.\n");
    return 0;
}
