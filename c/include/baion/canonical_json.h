#ifndef BAION_CANONICAL_JSON_H
#define BAION_CANONICAL_JSON_H

#include <cJSON.h>

/* Canonicalize any cJSON value. Returns heap-allocated string. Caller must free(). */
char* baion_canonicalize_json(const cJSON* value);

#endif /* BAION_CANONICAL_JSON_H */
