/* BAION canonical hash CLI for C — canonicalize-then-hash.
 *
 * Reads a UTF-8 JSON document on stdin, canonicalizes it, computes
 * SHA-256 of the canonical bytes, prints lowercase hex + newline.
 * Exit 0 on success; nonzero on parse error. */

#include "baion/canonical_json.h"
#include "baion/public_types.h"
#include "baion/sha256.h"

#include <cJSON.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Slurp all of stdin into a NUL-terminated heap buffer. */
static char* read_stdin(size_t* out_len)
{
    size_t cap = 4096;
    size_t len = 0;
    char* buf = (char*)malloc(cap);
    if (!buf)
        return NULL;

    size_t got;
    while ((got = fread(buf + len, 1, cap - len - 1, stdin)) > 0)
    {
        len += got;
        if (len + 1 >= cap)
        {
            cap *= 2;
            char* nbuf = (char*)realloc(buf, cap);
            if (!nbuf)
            {
                free(buf);
                return NULL;
            }
            buf = nbuf;
        }
    }
    buf[len] = '\0';
    *out_len = len;
    return buf;
}

int main(void)
{
    size_t len = 0;
    char* input = read_stdin(&len);
    if (!input || len == 0)
    {
        fprintf(stderr, "baion_canon_hash: empty or unreadable input\n");
        free(input);
        return -BAION_ERR_PARSE;
    }

    /* Embedded NUL means the document is not a single well-formed UTF-8
       JSON text — cJSON would silently stop at the NUL, so reject. */
    if (strlen(input) != len)
    {
        fprintf(stderr, "baion_canon_hash: embedded NUL in input\n");
        free(input);
        return -BAION_ERR_PARSE;
    }

    /* require_null_terminated=1 rejects trailing garbage after the document
       (whitespace is allowed by cJSON's skip). */
    const char* parse_end = NULL;
    cJSON* root = cJSON_ParseWithOpts(input, &parse_end, 1);
    free(input);
    if (!root)
    {
        fprintf(stderr, "baion_canon_hash: JSON parse error\n");
        return -BAION_ERR_PARSE;
    }

    char* canonical = baion_canonicalize_json(root);
    cJSON_Delete(root);

    uint8_t hash[32];
    baion_sha256((const uint8_t*)canonical, strlen(canonical), hash);
    free(canonical);

    char hex[65];
    for (int i = 0; i < 32; i++)
        sprintf(hex + i * 2, "%02x", hash[i]);
    hex[64] = '\0';

    printf("%s\n", hex);
    return BAION_OK;
}
