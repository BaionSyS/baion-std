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

/* Pre-parse LEXICAL scan for raw control bytes: returns BAION_OK if the input
 * carries no raw byte < 0x20 inside string literals and no raw byte < 0x20
 * other than TAB/LF/CR between tokens, else BAION_ERR_PARSE. Must run BEFORE
 * cJSON parsing — cJSON accepts raw controls inside strings and skips any
 * byte <= 0x20 between tokens as whitespace, both of which RFC 8259 forbids,
 * so C would otherwise accept documents the sibling lineages reject. Escaped
 * forms (the backslash-t and backslash-u001F spellings) stay accepted: they
 * are escape TEXT, not raw bytes, so this byte-level check cannot
 * false-positive on them. */
int baion_reject_raw_controls(const char* input, size_t len);

/* Pre-parse scan of raw input bytes: returns BAION_OK if the whole byte
 * stream is well-formed UTF-8 per RFC 3629, else BAION_ERR_PARSE. Rejects
 * continuation bytes without a lead, truncated sequences, overlong encodings
 * (0xC0/0xC1 leads, 0xE0 0x80-0x9F, 0xF0 0x80-0x8F), encoded surrogates
 * (0xED 0xA0-0xBF), and values above U+10FFFF (0xF4 0x90+, 0xF5-0xFF leads).
 * Must run BEFORE cJSON parsing — cJSON copies string bytes through
 * unexamined, so C would otherwise hash byte streams the sibling lineages
 * reject at decode time. */
int baion_reject_invalid_utf8(const char* input, size_t len);

/* Pre-parse LEXICAL scan of escape shape inside string literals: returns
 * BAION_OK if every backslash is followed by one of the eight single-char
 * escapes (quote, backslash, slash, b, f, n, r, t) or by 'u' + exactly 4 hex
 * digits, else BAION_ERR_PARSE. Must run BEFORE cJSON parsing — cJSON's hex
 * decoding tolerates some short backslash-u forms. Surrogate PAIRING validity
 * is out of scope here; this scan judges lexical shape only. */
int baion_reject_malformed_escapes(const char* input, size_t len);

/* Pre-parse LEXICAL scan of RFC 8259 number token shape: returns BAION_OK if
 * every number token is optional '-', then '0' or [1-9] digits (no leading
 * zeros), then optional '.' followed by at least one digit (no bare trailing
 * dot), else BAION_ERR_PARSE. Exponent text is not judged here — that
 * verdict belongs to baion_reject_number_domain. Must run BEFORE cJSON
 * parsing — cJSON accepts leading zeros and bare trailing dots that the
 * sibling lineages reject. */
int baion_reject_number_grammar(const char* input, size_t len);

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
