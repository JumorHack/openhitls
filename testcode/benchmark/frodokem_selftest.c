/*
 * This file is part of the openHiTLS project.
 *
 * openHiTLS is licensed under the Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan PSL v2.
 * You may obtain a copy of Mulan PSL v2 at:
 *
 *     http://license.coscl.org.cn/MulanPSL2
 *
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
 * EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
 * MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
 * See the Mulan PSL v2 for more details.
 */

/*
 * FrodoKEM functional self-test (public EAL API).
 *
 * Independent of the SDV test harness: it only uses public headers, so it
 * builds in the benchmark tree alongside openhitls_benchmark / frodokem_micro
 * and exercises the SAME NEON-enabled library.
 *
 * For each of the six parameter sets it performs many KeyGen -> Encaps ->
 * Decaps round-trips and checks that the encapsulated and decapsulated shared
 * secrets are identical.  Because FrodoKEM's FO transform re-runs the full
 * Encaps (A generation, sampling, both matrix products) inside Decaps and
 * compares, a matching shared secret confirms the entire optimized code path
 * is correct; any error in A generation, the S^T->S transpose, the
 * outer-product MAC kernel, or the sampler would make the secrets diverge.
 *
 * Exit code 0 = all round-trips matched; non-zero = at least one mismatch.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "crypt_errno.h"
#include "crypt_algid.h"
#include "crypt_eal_pkey.h"
#include "crypt_eal_rand.h"
#include "crypt_util_rand.h"

#define FRODO_CT_MAX 22528 /* >= 1344 ciphertext (21696) */
#define FRODO_SS_MAX 32    /* 1344 shared-secret size   */

static const struct {
    int32_t id;
    const char *name;
} g_params[] = {
    {CRYPT_KEM_TYPE_FRODOKEM_640_AES, "frodo-640-aes"},
    {CRYPT_KEM_TYPE_FRODOKEM_976_AES, "frodo-976-aes"},
    {CRYPT_KEM_TYPE_FRODOKEM_1344_AES, "frodo-1344-aes"},
    {CRYPT_KEM_TYPE_FRODOKEM_640_SHAKE, "frodo-640-shake"},
    {CRYPT_KEM_TYPE_FRODOKEM_976_SHAKE, "frodo-976-shake"},
    {CRYPT_KEM_TYPE_FRODOKEM_1344_SHAKE, "frodo-1344-shake"},
};

#if defined(HITLS_CRYPTO_PROVIDER)
static int32_t ProviderRand(uint8_t *rand, uint32_t randLen)
{
    return CRYPT_EAL_RandbytesEx(NULL, rand, randLen);
}
static int32_t ProviderRandEx(void *libCtx, uint8_t *rand, uint32_t randLen)
{
    return CRYPT_EAL_RandbytesEx((CRYPT_EAL_LibCtx *)libCtx, rand, randLen);
}
#endif

static int32_t RandInit(void)
{
#if defined(HITLS_CRYPTO_PROVIDER)
    int32_t ret = CRYPT_EAL_ProviderRandInitCtx(NULL, CRYPT_RAND_SHA256, "provider=default", NULL, 0, NULL);
    if (ret != CRYPT_SUCCESS) {
        return ret;
    }
    CRYPT_RandRegist(ProviderRand);
    CRYPT_RandRegistEx(ProviderRandEx);
    return CRYPT_SUCCESS;
#else
    return CRYPT_EAL_RandInit(CRYPT_RAND_SHA256, NULL, NULL, NULL, 0);
#endif
}

static void RandCleanup(void)
{
#if defined(HITLS_CRYPTO_PROVIDER)
    CRYPT_RandRegist(NULL);
    CRYPT_RandRegistEx(NULL);
#endif
    CRYPT_EAL_RandDeinitEx(NULL);
}

/* One KeyGen + Encaps + Decaps round-trip; returns 0 on match. */
static int RoundTrip(int32_t paraId)
{
    int rc = 1;
    CRYPT_EAL_PkeyCtx *ctx = CRYPT_EAL_PkeyNewCtx(CRYPT_PKEY_FRODOKEM);
    if (ctx == NULL) {
        printf("    NewCtx failed\n");
        return 1;
    }
    if (CRYPT_EAL_PkeyCtrl(ctx, CRYPT_CTRL_SET_PARA_BY_ID, &paraId, sizeof(paraId)) != CRYPT_SUCCESS) {
        printf("    SetPara failed\n");
        goto END;
    }
    if (CRYPT_EAL_PkeyGen(ctx) != CRYPT_SUCCESS) {
        printf("    KeyGen failed\n");
        goto END;
    }

    uint8_t ct[FRODO_CT_MAX];
    uint32_t ctLen = sizeof(ct);
    uint8_t ssEnc[FRODO_SS_MAX];
    uint32_t ssEncLen = sizeof(ssEnc);
    uint8_t ssDec[FRODO_SS_MAX];
    uint32_t ssDecLen = sizeof(ssDec);

    if (CRYPT_EAL_PkeyEncaps(ctx, ct, &ctLen, ssEnc, &ssEncLen) != CRYPT_SUCCESS) {
        printf("    Encaps failed\n");
        goto END;
    }
    if (CRYPT_EAL_PkeyDecaps(ctx, ct, ctLen, ssDec, &ssDecLen) != CRYPT_SUCCESS) {
        printf("    Decaps failed\n");
        goto END;
    }
    if (ssEncLen != ssDecLen || memcmp(ssEnc, ssDec, ssEncLen) != 0) {
        printf("    SHARED-SECRET MISMATCH (len %u vs %u)\n", ssEncLen, ssDecLen);
        goto END;
    }
    rc = 0;
END:
    CRYPT_EAL_PkeyFreeCtx(ctx);
    return rc;
}

int main(int argc, char **argv)
{
    int iters = (argc >= 2) ? atoi(argv[1]) : 100;
    if (iters <= 0) {
        iters = 100;
    }

    if (RandInit() != CRYPT_SUCCESS) {
        printf("RandInit failed\n");
        return 2;
    }

    printf("FrodoKEM functional self-test: %d round-trips per parameter set\n", iters);
    int failures = 0;
    for (size_t p = 0; p < sizeof(g_params) / sizeof(g_params[0]); p++) {
        int bad = 0;
        for (int i = 0; i < iters; i++) {
            if (RoundTrip(g_params[p].id) != 0) {
                bad++;
                if (bad == 1) {
                    printf("  %-16s : FAIL (iteration %d)\n", g_params[p].name, i);
                }
            }
        }
        if (bad == 0) {
            printf("  %-16s : PASS (%d/%d)\n", g_params[p].name, iters, iters);
        } else {
            printf("  %-16s : FAIL (%d/%d mismatched)\n", g_params[p].name, bad, iters);
            failures += bad;
        }
    }

    RandCleanup();

    if (failures == 0) {
        printf("\nALL PASS: every shared secret matched.\n");
        return 0;
    }
    printf("\nFAILED: %d round-trips mismatched.\n", failures);
    return 1;
}
