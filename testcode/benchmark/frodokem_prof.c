/*
 * This file is part of the openHiTLS project. Licensed under Mulan PSL v2.
 *
 * frodokem_prof.c -- single-operation profiling driver for FrodoKEM-640-AES.
 *
 * Loops ONE of {KeyGen, Encaps, Decaps} so that `perf record` attributes
 * cycles per function for that operation alone.  Used (with the liboqs
 * driver) to localise the openHiTLS-vs-liboqs gap (paper experiment E9).
 *
 *   ./frodokem_prof {kg|en|de} [iters]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "crypt_errno.h"
#include "crypt_algid.h"
#include "crypt_eal_pkey.h"
#include "crypt_eal_rand.h"
#include "crypt_util_rand.h"

#define CT_MAX 22528
#define SS_MAX 32

static int32_t ProviderRand(uint8_t *rand, uint32_t randLen)
{
    return CRYPT_EAL_RandbytesEx(NULL, rand, randLen);
}
static int32_t ProviderRandEx(void *libCtx, uint8_t *rand, uint32_t randLen)
{
    return CRYPT_EAL_RandbytesEx((CRYPT_EAL_LibCtx *)libCtx, rand, randLen);
}
static int32_t RandInit(void)
{
    int32_t ret = CRYPT_EAL_ProviderRandInitCtx(NULL, CRYPT_RAND_SHA256,
                                                "provider=default", NULL, 0, NULL);
    if (ret != CRYPT_SUCCESS) {
        return ret;
    }
    CRYPT_RandRegist(ProviderRand);
    CRYPT_RandRegistEx(ProviderRandEx);
    return CRYPT_EAL_RandInit(CRYPT_RAND_SHA256, NULL, NULL, NULL, 0);
}

int main(int argc, char **argv)
{
    const char *mode = (argc > 1) ? argv[1] : "kg";
    long iters = (argc > 2) ? atol(argv[2]) : 12000;

    if (RandInit() != CRYPT_SUCCESS) {
        fprintf(stderr, "RandInit failed\n");
        return 1;
    }
    int32_t paraId = CRYPT_KEM_TYPE_FRODOKEM_640_AES;
    CRYPT_EAL_PkeyCtx *ctx = CRYPT_EAL_PkeyNewCtx(CRYPT_PKEY_FRODOKEM);
    if (ctx == NULL) { fprintf(stderr, "NewCtx failed\n"); return 1; }
    if (CRYPT_EAL_PkeyCtrl(ctx, CRYPT_CTRL_SET_PARA_BY_ID, &paraId, sizeof(paraId)) != CRYPT_SUCCESS) {
        fprintf(stderr, "SetPara failed\n"); return 1;
    }
    if (CRYPT_EAL_PkeyGen(ctx) != CRYPT_SUCCESS) { fprintf(stderr, "KeyGen failed\n"); return 1; }

    uint8_t ct[CT_MAX];  uint32_t ctLen = sizeof(ct);
    uint8_t ssE[SS_MAX]; uint32_t ssELen = sizeof(ssE);
    uint8_t ssD[SS_MAX]; uint32_t ssDLen = sizeof(ssD);
    if (CRYPT_EAL_PkeyEncaps(ctx, ct, &ctLen, ssE, &ssELen) != CRYPT_SUCCESS) {
        fprintf(stderr, "Encaps (setup) failed\n"); return 1;
    }

    volatile uint32_t sink = 0;
    if (strcmp(mode, "kg") == 0) {
        for (long i = 0; i < iters; i++) {
            (void)CRYPT_EAL_PkeyGen(ctx);
        }
    } else if (strcmp(mode, "en") == 0) {
        for (long i = 0; i < iters; i++) {
            ctLen = sizeof(ct); ssELen = sizeof(ssE);
            (void)CRYPT_EAL_PkeyEncaps(ctx, ct, &ctLen, ssE, &ssELen);
            sink ^= ct[0];
        }
    } else { /* de */
        for (long i = 0; i < iters; i++) {
            ssDLen = sizeof(ssD);
            (void)CRYPT_EAL_PkeyDecaps(ctx, ct, ctLen, ssD, &ssDLen);
            sink ^= ssD[0];
        }
    }
    (void)sink;
    CRYPT_EAL_PkeyFreeCtx(ctx);
    fprintf(stderr, "openhitls done: %s x%ld\n", mode, iters);
    return 0;
}
