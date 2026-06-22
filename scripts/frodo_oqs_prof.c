/*
 * frodo_oqs_prof.c -- single-operation profiling driver for liboqs
 * FrodoKEM-640-AES (paper experiment E9, the liboqs side).
 *
 * Mirrors frodokem_prof.c: loops ONE of {KeyGen, Encaps, Decaps} so perf
 * attributes cycles per function for that operation alone.
 *
 *   ./frodo_oqs_prof {kg|en|de} [iters]
 *
 * Build: gcc -O2 -g -I <liboqs>/build/include frodo_oqs_prof.c \
 *            <liboqs>/build/lib/liboqs.a -o frodo_oqs_prof -lm -lpthread
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <oqs/oqs.h>

int main(int argc, char **argv)
{
    const char *mode = (argc > 1) ? argv[1] : "kg";
    long iters = (argc > 2) ? atol(argv[2]) : 12000;

    OQS_KEM *kem = OQS_KEM_new(OQS_KEM_alg_frodokem_640_aes);
    if (kem == NULL) { fprintf(stderr, "OQS_KEM_new failed\n"); return 1; }

    uint8_t *pk  = malloc(kem->length_public_key);
    uint8_t *sk  = malloc(kem->length_secret_key);
    uint8_t *ct  = malloc(kem->length_ciphertext);
    uint8_t *ss  = malloc(kem->length_shared_secret);
    uint8_t *ss2 = malloc(kem->length_shared_secret);
    if (!pk || !sk || !ct || !ss || !ss2) { fprintf(stderr, "malloc failed\n"); return 1; }

    OQS_KEM_keypair(kem, pk, sk);
    OQS_KEM_encaps(kem, ct, ss, pk);

    volatile uint8_t sink = 0;
    if (strcmp(mode, "kg") == 0) {
        for (long i = 0; i < iters; i++) { OQS_KEM_keypair(kem, pk, sk); sink ^= pk[0]; }
    } else if (strcmp(mode, "en") == 0) {
        for (long i = 0; i < iters; i++) { OQS_KEM_encaps(kem, ct, ss, pk); sink ^= ct[0]; }
    } else { /* de */
        for (long i = 0; i < iters; i++) { OQS_KEM_decaps(kem, ss2, ct, sk); sink ^= ss2[0]; }
    }
    (void)sink;
    OQS_KEM_free(kem);
    fprintf(stderr, "liboqs done: %s x%ld\n", mode, iters);
    return 0;
}
