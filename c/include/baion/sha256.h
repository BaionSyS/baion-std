#ifndef BAION_SHA256_H
#define BAION_SHA256_H

#include <stddef.h>
#include <stdint.h>

typedef struct
{
    uint32_t state[8];
    uint64_t bitcount;
    uint8_t buffer[64];
} baion_sha256_ctx;

void baion_sha256_init(baion_sha256_ctx* ctx);
void baion_sha256_update(baion_sha256_ctx* ctx, const uint8_t* data, size_t len);
void baion_sha256_final(baion_sha256_ctx* ctx, uint8_t hash[32]);

/* Convenience: hash data in one call */
void baion_sha256(const uint8_t* data, size_t len, uint8_t hash[32]);

#endif /* BAION_SHA256_H */
