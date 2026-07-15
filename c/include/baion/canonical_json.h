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

#endif /* BAION_CANONICAL_JSON_H */
