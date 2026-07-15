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

    /* Pre-parse BOM rejection (library-level scan): cJSON silently skips a
       leading UTF-8 BOM, so a BOM-prefixed document would hash identically
       to its BOM-free twin. Reviewer contract: reject with exit 1. */
    if (baion_reject_bom(input, len) != BAION_OK)
    {
        fprintf(stderr, "baion_canon_hash: leading UTF-8 BOM in input is unsupported\n");
        free(input);
        return 1;
    }

    /* Pre-parse UTF-8 well-formedness rejection (library-level scan): cJSON
       copies string bytes through unexamined, so invalid byte sequences the
       sibling lineages reject at decode time would hash here. Reviewer
       contract: reject with exit 1. */
    if (baion_reject_invalid_utf8(input, len) != BAION_OK)
    {
        fprintf(stderr, "baion_canon_hash: invalid UTF-8 byte sequence in input\n");
        free(input);
        return 1;
    }

    /* Pre-parse U+0000 rejection (library-level scan): cJSON decodes the
       u0000 escape into a NUL byte that truncates the C string, so distinct
       documents would collapse onto one canonical form. Reviewer contract:
       reject with exit 1. */
    if (baion_reject_u0000(input, len) != BAION_OK)
    {
        fprintf(stderr, "baion_canon_hash: U+0000 in input is unsupported\n");
        free(input);
        return 1;
    }

    /* Pre-parse raw-control rejection (library-level LEXICAL scan): cJSON
       accepts raw control bytes inside strings and skips non-whitespace
       control bytes between tokens, both forbidden by RFC 8259 — the sibling
       lineages reject them. Reviewer contract: reject with exit 1. */
    if (baion_reject_raw_controls(input, len) != BAION_OK)
    {
        fprintf(stderr, "baion_canon_hash: raw control byte in input is unsupported\n");
        free(input);
        return 1;
    }

    /* Pre-parse escape-shape rejection (library-level LEXICAL scan): cJSON
       tolerates some short backslash-u forms that the sibling lineages
       reject. Reviewer contract: reject with exit 1. */
    if (baion_reject_malformed_escapes(input, len) != BAION_OK)
    {
        fprintf(stderr, "baion_canon_hash: malformed string escape in input is invalid\n");
        free(input);
        return 1;
    }

    /* Pre-parse number-shape rejection (library-level LEXICAL scan): cJSON
       accepts leading zeros and bare trailing dots that RFC 8259 forbids and
       the sibling lineages reject. Reviewer contract: reject with exit 1. */
    if (baion_reject_number_grammar(input, len) != BAION_OK)
    {
        fprintf(stderr, "baion_canon_hash: invalid number token shape in input\n");
        free(input);
        return 1;
    }

    /* Pre-parse number-domain rejection (library-level LEXICAL scan): cJSON
       collapses "100" and "1e2" onto the same double, so only the raw token
       spelling can enforce the plain-decimal domain (no exponent notation,
       integers within 2^53, fractions in [1e-6, 1e21)). Reviewer contract:
       reject with exit 1. */
    if (baion_reject_number_domain(input, len) != BAION_OK)
    {
        fprintf(stderr,
                "baion_canon_hash: number outside plain-decimal domain is unsupported\n");
        free(input);
        return 1;
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

    /* Post-parse duplicate-key rejection (library-level walk): key sorting
       would silently reorder duplicates and hash whichever the serializer
       emits, collapsing distinct documents. Reviewer contract: reject with
       exit 1, comparing DECODED key names (escaped and plain forms collide). */
    if (baion_reject_duplicate_keys(root) != BAION_OK)
    {
        fprintf(stderr, "baion_canon_hash: duplicate object key in input is unsupported\n");
        cJSON_Delete(root);
        return 1;
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
