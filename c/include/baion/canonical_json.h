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

#endif /* BAION_CANONICAL_JSON_H */
