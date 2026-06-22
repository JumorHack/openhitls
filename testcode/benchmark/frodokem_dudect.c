/*
 * This file is part of the openHiTLS project.
 *
 * openHiTLS is licensed under the Mulan PSL v2.
 *
 * frodokem_dudect.c -- dudect constant-time test for the NEON CDF sampler
 * FrodoCommonSampleNFromR (paper experiment E8).
 *
 * The sampler is the kernel where constant-timeness is non-trivial: it makes a
 * data-dependent sign decision and walks the CDF table.  We test it with
 * dudect's fixed-vs-random methodology:
 *   class 0: fixed (all-zero) randomness rBytes;
 *   class 1: uniformly random rBytes.
 * A constant-time implementation yields statistically indistinguishable timing
 * (Welch |t| < 4.5).  Our kernel uses only branch-free cmgt/ushr/bsl and walks
 * the whole table every call, so it should pass.
 *
 * Build: only meaningful with HITLS_CRYPTO_FRODOKEM_ARMV8=ON (the NEON sampler).
 * Needs the header-only dudect.h in this directory; scripts/run_e8_dudect.sh
 * fetches it before building.
 *
 * Env: DUDECT_BATCHES (default 2000) bounds the run so it terminates.
 */
#define _GNU_SOURCE

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "crypt_algid.h"
#include "frodo_local.h"

extern void FrodoCommonSampleNFromR(uint16_t *samples, size_t n,
                                    const uint16_t *cdfTable, size_t cdfLen,
                                    const uint8_t *rBytes);

#define DUDECT_IMPLEMENTATION
#include "dudect.h"

/* Sampler parameters, fixed once in main(). */
static const uint16_t *g_cdf;
static size_t          g_cdfLen;
static size_t          g_n;     /* samples per call (= n * nBar) */
static uint16_t       *g_out;   /* scratch output, g_n uint16 */

uint8_t do_one_computation(uint8_t *data)
{
    FrodoCommonSampleNFromR(g_out, g_n, g_cdf, g_cdfLen, data);
    /* Fold the output so the compiler cannot elide the call. */
    uint16_t acc = 0;
    for (size_t i = 0; i < g_n; i++) {
        acc ^= g_out[i];
    }
    return (uint8_t)(acc ^ (acc >> 8));
}

void prepare_inputs(dudect_config_t *c, uint8_t *input_data, uint8_t *classes)
{
    randombytes(input_data, (size_t)c->number_measurements * c->chunk_size);
    for (size_t i = 0; i < c->number_measurements; i++) {
        classes[i] = randombit();
        if (classes[i] == 0) {
            /* fixed class: all-zero randomness */
            memset(input_data + i * c->chunk_size, 0x00, c->chunk_size);
        }
        /* class 1 keeps its random bytes */
    }
}

int main(void)
{
    FrodoKemParams *p = FrodoGetParamsById(CRYPT_KEM_TYPE_FRODOKEM_640_AES);
    if (p == NULL) {
        fprintf(stderr, "FrodoGetParamsById(FRODOKEM_640_AES) returned NULL\n");
        return 2;
    }
    g_cdf    = p->cdfTable;
    g_cdfLen = p->cdfLen;
    g_n      = (size_t)p->n * p->nBar;          /* 640 * 8 = 5120 */
    g_out    = malloc(g_n * sizeof(uint16_t));
    if (g_out == NULL) {
        return 2;
    }
    size_t chunk = g_n * 2;                       /* 2 randomness bytes/sample */

    long max_batches = 2000;
    const char *env = getenv("DUDECT_BATCHES");
    if (env != NULL) {
        max_batches = atol(env);
    }

    dudect_config_t config = {
        .chunk_size          = chunk,
        .number_measurements = 5000,
    };
    dudect_ctx_t ctx;
    dudect_init(&ctx, &config);

    printf("E8 dudect: FrodoCommonSampleNFromR (NEON), Frodo-640 CDF "
           "(cdfLen=%zu), n=%zu samples/call, chunk=%zu bytes, "
           "%d meas/batch, max %ld batches\n",
           g_cdfLen, g_n, chunk, (int)config.number_measurements, max_batches);
    printf("class 0 = fixed all-zero rBytes; class 1 = random rBytes. "
           "Pass: |t| stays below 4.5.\n");
    fflush(stdout);

    dudect_state_t state = DUDECT_NO_LEAKAGE_EVIDENCE_YET;
    long b = 0;
    while (b < max_batches) {
        state = dudect_main(&ctx);
        b++;
        if (state == DUDECT_LEAKAGE_FOUND) {
            printf("E8 RESULT: dudect reports leakage after %ld batches "
                   "(%ld measurements)\n", b, b * 5000L);
            break;
        }
    }
    if (state != DUDECT_LEAKAGE_FOUND) {
        printf("E8 RESULT: no leakage evidence after %ld batches "
               "(%ld measurements); the NEON sampler is consistent with "
               "constant-time behaviour.\n", b, b * 5000L);
    }

    dudect_free(&ctx);
    free(g_out);
    return (state == DUDECT_LEAKAGE_FOUND) ? 1 : 0;
}
