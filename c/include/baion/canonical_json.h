#ifndef BAION_CANONICAL_JSON_H
#define BAION_CANONICAL_JSON_H

#include <cJSON.h>
#include <stddef.h>

/* Canonicalize any cJSON value. Returns heap-allocated string. Caller must free(). */
char* baion_canonicalize_json(const cJSON* value);

/* Pre-parse scan of raw JSON input bytes: returns BAION_OK if the input is
 * free of U+0000 (raw NUL bytes and active backslash-u0000 escapes), else
 * BAION_ERR_PARSE. Must run BEFORE cJSON parsing — cJSON decodes the u0000 escape to a
 * NUL byte inside a C string, silently truncating it and collapsing distinct
 * documents onto one canonical form (hash collision). */
int baion_reject_u0000(const char* input, size_t len);

/* Post-parse walk of a decoded cJSON tree: returns BAION_OK if no object at
 * any nesting depth (including objects inside arrays) carries two members
 * with the same DECODED key name, else BAION_ERR_PARSE. Must run AFTER cJSON
 * parsing — escapes like backslash-u0061 decode to the same bytes as "a", so only the
 * decoded names in child->string can be compared; a raw-text scan would miss
 * escaped-form duplicates. */
int baion_reject_duplicate_keys(const cJSON* root);

/* Pre-parse scan of raw JSON input bytes: returns BAION_OK if the first
 * bytes are NOT a UTF-8 byte-order mark (EF BB BF), else BAION_ERR_PARSE.
 * Must run BEFORE cJSON parsing — cJSON silently skips a leading BOM, so a
 * BOM-prefixed document and its BOM-free twin would hash identically while
 * being byte-distinct on the wire. */
int baion_reject_bom(const char* input, size_t len);

/* Pre-parse LEXICAL scan of raw JSON number tokens: returns BAION_OK if every
 * number token in the input is inside the plain-decimal domain, else
 * BAION_ERR_PARSE. Must run BEFORE cJSON parsing — cJSON collapses "100" and
 * "1e2" onto the same double, so only the raw token spelling can distinguish
 * them. Out of domain: any exponent notation (e/E); integer tokens (no '.')
 * whose magnitude exceeds 2^53 (digit-string compare, never via double);
 * fraction tokens whose value v has (v != 0 && |v| < 1e-6) or |v| >= 1e21.
 * Precondition: input[len] == '\0' (the fraction check hands the token
 * suffix to strtod, which stops at the token's non-number delimiter or at
 * that terminator). */
int baion_reject_number_domain(const char* input, size_t len);

#endif /* BAION_CANONICAL_JSON_H */
