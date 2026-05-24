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

#include <stddef.h>
#include <string.h>
#include "crypt_algid.h"
#include "crypt_errno.h"
#include "crypt_eal_pkey.h"
#include "crypt_eal_md.h"
#include "benchmark.h"

/* Frodo ciphertext sizes: 640→9752, 976→15792, 1344→21696 (incl. salt) */
#define FRODO_CT_MAX     22528  /* round up to 22 KiB */
#define FRODO_SS_MAX     32     /* Frodo-1344 shared-secret size */

static const char *GetParaName(int32_t paraId)
{
    switch (paraId) {
        case CRYPT_KEM_TYPE_FRODOKEM_640_AES:    return "frodokem-640-aes";
        case CRYPT_KEM_TYPE_FRODOKEM_976_AES:    return "frodokem-976-aes";
        case CRYPT_KEM_TYPE_FRODOKEM_1344_AES:   return "frodokem-1344-aes";
        case CRYPT_KEM_TYPE_FRODOKEM_640_SHAKE:  return "frodokem-640-shake";
        case CRYPT_KEM_TYPE_FRODOKEM_976_SHAKE:  return "frodokem-976-shake";
        case CRYPT_KEM_TYPE_FRODOKEM_1344_SHAKE: return "frodokem-1344-shake";
        default: return "unknown";
    }
}

static int32_t FrodokemSetUp(void **ctx, const Operation *op, int32_t algId, int32_t paraId)
{
    (void)op;
    CRYPT_EAL_PkeyCtx *pkeyCtx = CRYPT_EAL_PkeyNewCtx(algId);
    if (pkeyCtx == NULL) {
        printf("Failed to create frodokem pkey context\n");
        return CRYPT_MEM_ALLOC_FAIL;
    }
    int32_t ret = CRYPT_EAL_PkeyCtrl(pkeyCtx, CRYPT_CTRL_SET_PARA_BY_ID, &paraId, sizeof(paraId));
    if (ret != CRYPT_SUCCESS) {
        printf("Failed to set frodokem alg info, ret = %08x\n", ret);
        CRYPT_EAL_PkeyFreeCtx(pkeyCtx);
        return ret;
    }
    ret = CRYPT_EAL_PkeyGen(pkeyCtx);
    if (ret != CRYPT_SUCCESS) {
        printf("Failed to gen frodokem key, ret = %08x\n", ret);
        CRYPT_EAL_PkeyFreeCtx(pkeyCtx);
        return ret;
    }
    *ctx = pkeyCtx;
    return CRYPT_SUCCESS;
}

static void FrodokemTearDown(void *ctx)
{
    CRYPT_EAL_PkeyFreeCtx(ctx);
}

static int32_t FrodokemKeyGen(void *ctx, const BenchExecOptions *opts)
{
    int rc = CRYPT_SUCCESS;
    BENCH_RUN_VA(CRYPT_EAL_PkeyGen(ctx), rc, CRYPT_SUCCESS, -1, opts,
                 "%s keyGen", GetParaName(opts->paraId));
    return rc;
}

static int32_t FrodokemEncaps(void *ctx, const BenchExecOptions *opts)
{
    int rc;
    uint8_t ciphertext[FRODO_CT_MAX];
    uint32_t ciphertextLen = sizeof(ciphertext);
    uint8_t sharedKey[FRODO_SS_MAX];
    uint32_t sharedKeyLen = sizeof(sharedKey);

    BENCH_RUN_VA(CRYPT_EAL_PkeyEncaps(ctx, ciphertext, &ciphertextLen, sharedKey, &sharedKeyLen),
                 rc, CRYPT_SUCCESS, -1, opts, "%s encaps", GetParaName(opts->paraId));
    return rc;
}

static int32_t FrodokemDecaps(void *ctx, const BenchExecOptions *opts)
{
    int rc;
    uint8_t ciphertext[FRODO_CT_MAX];
    uint32_t ciphertextLen = sizeof(ciphertext);
    uint8_t sharedKey[FRODO_SS_MAX];
    uint32_t sharedKeyLen = sizeof(sharedKey);

    /* Generate a valid ciphertext once before timing decaps. */
    rc = CRYPT_EAL_PkeyEncaps(ctx, ciphertext, &ciphertextLen, sharedKey, &sharedKeyLen);
    if (rc != CRYPT_SUCCESS) {
        printf("Failed to encap before decap bench, ret = %08x\n", rc);
        return rc;
    }

    BENCH_RUN_VA(CRYPT_EAL_PkeyDecaps(ctx, ciphertext, ciphertextLen, sharedKey, &sharedKeyLen),
                 rc, CRYPT_SUCCESS, -1, opts, "%s decaps", GetParaName(opts->paraId));
    return rc;
}

static int32_t g_paraIds[] = {
    CRYPT_KEM_TYPE_FRODOKEM_640_AES,
    CRYPT_KEM_TYPE_FRODOKEM_976_AES,
    CRYPT_KEM_TYPE_FRODOKEM_1344_AES,
    CRYPT_KEM_TYPE_FRODOKEM_640_SHAKE,
    CRYPT_KEM_TYPE_FRODOKEM_976_SHAKE,
    CRYPT_KEM_TYPE_FRODOKEM_1344_SHAKE,
};

DEFINE_OPS_KEM(Frodokem, CRYPT_PKEY_FRODOKEM);
DEFINE_BENCH_CTX_PARA_FIXLEN(Frodokem, g_paraIds, SIZEOF(g_paraIds));
