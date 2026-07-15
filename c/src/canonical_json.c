/* BAION canonical JSON for C — public standalone library.
 *
 * Keys sorted lexicographically at every nesting level, no whitespace,
 * minimal escaping (forward slash / NOT escaped).
 * Numbers: integers as integers, floats as minimal representation. */

#include "baion/canonical_json.h"

#include "baion/public_types.h"

#include <cJSON.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Dynamic string buffer. Allocation failure latches `oom`; every append
 * becomes a no-op once set, so the walk finishes cheaply and the public
 * entry point reports one defined failure (NULL) instead of any internal
 * path dereferencing a failed allocation. */
typedef struct
{
    char* data;
    size_t len;
    size_t cap;
    int oom;
} strbuf_t;

static void strbuf_init(strbuf_t* sb)
{
    sb->cap = 512;
    sb->data = (char*)malloc(sb->cap);
    sb->len = 0;
    sb->oom = (sb->data == NULL);
    if (!sb->oom)
        sb->data[0] = '\0';
}

static void strbuf_ensure(strbuf_t* sb, size_t extra)
{
    if (sb->oom)
        return;
    /* len + extra + 1 must not wrap: a wrapped "needed" would pass the
     * capacity test and let the memcpy in strbuf_append run off the end. */
    if (extra > SIZE_MAX - sb->len - 1)
    {
        sb->oom = 1;
        return;
    }
    size_t needed = sb->len + extra + 1;
    if (needed > sb->cap)
    {
        size_t cap = sb->cap;
        while (cap < needed)
        {
            if (cap > SIZE_MAX / 2)
            {
                cap = needed; /* doubling would wrap; exact size is enough */
                break;
            }
            cap *= 2;
        }
        /* realloc into a temporary: assigning a NULL return straight to
         * sb->data would leak the original block and lose the buffer. */
        char* grown = (char*)realloc(sb->data, cap);
        if (!grown)
        {
            sb->oom = 1;
            return;
        }
        sb->data = grown;
        sb->cap = cap;
    }
}

static void strbuf_append(strbuf_t* sb, const char* s, size_t n)
{
    strbuf_ensure(sb, n);
    if (sb->oom)
        return;
    memcpy(sb->data + sb->len, s, n);
    sb->len += n;
    sb->data[sb->len] = '\0';
}

static void strbuf_appendc(strbuf_t* sb, char c)
{
    strbuf_ensure(sb, 1);
    if (sb->oom)
        return;
    sb->data[sb->len++] = c;
    sb->data[sb->len] = '\0';
}

static void strbuf_appends(strbuf_t* sb, const char* s)
{
    strbuf_append(sb, s, strlen(s));
}

/* Write JSON-quoted string with minimal escaping.
   Only escapes: " \ and control chars 0x00-0x1F. Forward slash / is NOT escaped. */
static void write_json_string(strbuf_t* sb, const char* s)
{
    strbuf_appendc(sb, '"');
    for (const char* p = s; *p; p++)
    {
        unsigned char c = (unsigned char)*p;
        switch (c)
        {
        case '"':
            strbuf_appends(sb, "\\\"");
            break;
        case '\\':
            strbuf_appends(sb, "\\\\");
            break;
        case '\b':
            strbuf_appends(sb, "\\b");
            break;
        case '\f':
            strbuf_appends(sb, "\\f");
            break;
        case '\n':
            strbuf_appends(sb, "\\n");
            break;
        case '\r':
            strbuf_appends(sb, "\\r");
            break;
        case '\t':
            strbuf_appends(sb, "\\t");
            break;
        default:
            if (c < 0x20)
            {
                char esc[8];
                snprintf(esc, sizeof(esc), "\\u%04x", c);
                strbuf_appends(sb, esc);
            }
            else
            {
                strbuf_appendc(sb, (char)c);
            }
        }
    }
    strbuf_appendc(sb, '"');
}

/* Forward declaration */
static void canonicalize_value(strbuf_t* sb, const cJSON* item);

/* Compare function for qsort on cJSON key names */
static int key_compare(const void* a, const void* b)
{
    const cJSON* ia = *(const cJSON**)a;
    const cJSON* ib = *(const cJSON**)b;
    return strcmp(ia->string, ib->string);
}

static void canonicalize_object(strbuf_t* sb, const cJSON* obj)
{
    /* Count children */
    int count = 0;
    const cJSON* child;
    for (child = obj->child; child; child = child->next)
        count++;

    if (count == 0)
    {
        strbuf_appends(sb, "{}");
        return;
    }

    /* Collect pointers and sort by key */
    const cJSON** keys = (const cJSON**)malloc((size_t)count * sizeof(cJSON*));
    if (!keys)
    {
        sb->oom = 1;
        return;
    }
    int i = 0;
    for (child = obj->child; child; child = child->next)
    {
        keys[i++] = child;
    }
    qsort(keys, (size_t)count, sizeof(cJSON*), key_compare);

    strbuf_appendc(sb, '{');
    for (i = 0; i < count; i++)
    {
        if (i > 0)
            strbuf_appendc(sb, ',');
        write_json_string(sb, keys[i]->string);
        strbuf_appendc(sb, ':');
        canonicalize_value(sb, keys[i]);
    }
    strbuf_appendc(sb, '}');

    free(keys);
}

static void canonicalize_array(strbuf_t* sb, const cJSON* arr)
{
    strbuf_appendc(sb, '[');
    const cJSON* child;
    int first = 1;
    for (child = arr->child; child; child = child->next)
    {
        if (!first)
            strbuf_appendc(sb, ',');
        first = 0;
        canonicalize_value(sb, child);
    }
    strbuf_appendc(sb, ']');
}

/* Format number: integers as integers, floats as minimal representation.
   cJSON stores valueint and valuedouble. We check if the double is an integer value. */
static void write_number(strbuf_t* sb, const cJSON* item)
{
    double d = item->valuedouble;

    if (isnan(d) || isinf(d))
    {
        strbuf_appends(sb, "null");
        return;
    }

    /* CROSS-LINEAGE CONTRACT: integer-valued floats serialize without
     * trailing decimal (RFC 8785 §3.2.2.3 / ECMA-262 §7.1.12.1). All
     * language implementations emit 1.0 → "1", -3.0 → "-3", 1.5 → "1.5";
     * disagreement on this branch breaks SHA-256 digest parity. */
    /* Range check MUST precede the integer conversion: for |d| >= 2^63
     * (e.g. 1e20, inside the admitted domain |v| < 1e21) the cast to
     * long long is undefined behavior (C11 6.3.1.4p1). Same guard order
     * as the C++ lineage. */
    if (fabs(d) < 1e15 && trunc(d) == d)
    {
        char buf[32];
        snprintf(buf, sizeof(buf), "%lld", (long long)d);
        strbuf_appends(sb, buf);
    }
    else
    {
        /* CROSS-LINEAGE CONTRACT: non-integer floats serialize as the
         * SHORTEST decimal string that roundtrips to the same double
         * (RFC 8785 §3.2.2.3 / ECMA-262 §7.1.12.1), reassembled WITHOUT
         * exponent notation. The number-domain gate guarantees the value
         * is 0 or |v| in [1e-6, 1e21), which is exactly the range where
         * ECMA-262 ToString never takes its exponent branch — so plain
         * positional layout is the canonical spelling. 17-digit %.17g
         * here previously printed 0.1 as 0.10000000000000001, diverging
         * from every RFC 8785 lineage. */

        /* Shortest digits: smallest precision whose %e output parses back
         * to the identical double. Locale-sensitive (%e / strtod use the
         * locale decimal point): this code assumes the default "C" locale;
         * if the process ever calls setlocale() with a comma-decimal
         * locale, the '.' scanning below breaks. */
        char sci[64];
        for (int prec = 1; prec <= 17; prec++)
        {
            snprintf(sci, sizeof(sci), "%.*e", prec - 1, d);
            if (strtod(sci, NULL) == d)
                break;
        }

        /* Pull apart [-]d[.ddd]e±XX into digit string D and n = exp10 + 1
         * (count of digits before the decimal point in positional form). */
        const char* s = sci;
        int neg = 0;
        if (*s == '-')
        {
            neg = 1;
            s++;
        }
        char digits[32];
        int dl = 0;
        digits[dl++] = *s++;
        if (*s == '.')
        {
            s++;
            while (*s != 'e' && *s != 'E')
                digits[dl++] = *s++;
        }
        s++; /* skip 'e'; strtol consumes the +/- sign of the exponent */
        int n = (int)strtol(s, NULL, 10) + 1;

        char out[64];
        int o = 0;
        if (neg)
            out[o++] = '-';
        if (dl <= n && n <= 21)
        {
            /* Integer-valued but too large for the %lld branch above
             * (|v| >= 1e15): all digits then zero-padding, no dot. */
            memcpy(out + o, digits, (size_t)dl);
            o += dl;
            for (int k = 0; k < n - dl; k++)
                out[o++] = '0';
        }
        else if (0 < n && n <= dl)
        {
            memcpy(out + o, digits, (size_t)n);
            o += n;
            out[o++] = '.';
            memcpy(out + o, digits + n, (size_t)(dl - n));
            o += dl - n;
        }
        else if (-5 <= n && n <= 0)
        {
            out[o++] = '0';
            out[o++] = '.';
            for (int k = 0; k < -n; k++)
                out[o++] = '0';
            memcpy(out + o, digits, (size_t)dl);
            o += dl;
        }
        else
        {
            /* Only reachable when a caller bypassed the number-domain gate
             * (programmatic tree with |v| >= 1e21 or |v| < 1e-6): emit a
             * best-effort spelling rather than corrupt memory. NON-CANONICAL. */
            snprintf(out, sizeof(out), "%.17g", d);
            strbuf_appends(sb, out);
            return;
        }
        out[o] = '\0';
        strbuf_appends(sb, out);
    }
}

static void canonicalize_value(strbuf_t* sb, const cJSON* item)
{
    if (!item)
    {
        strbuf_appends(sb, "null");
        return;
    }

    if (cJSON_IsNull(item))
    {
        strbuf_appends(sb, "null");
    }
    else if (cJSON_IsBool(item))
    {
        strbuf_appends(sb, cJSON_IsTrue(item) ? "true" : "false");
    }
    else if (cJSON_IsNumber(item))
    {
        write_number(sb, item);
    }
    else if (cJSON_IsString(item))
    {
        write_json_string(sb, item->valuestring);
    }
    else if (cJSON_IsArray(item))
    {
        canonicalize_array(sb, item);
    }
    else if (cJSON_IsObject(item))
    {
        canonicalize_object(sb, item);
    }
    else
    {
        strbuf_appends(sb, "null");
    }
}

int baion_reject_u0000(const char* input, size_t len)
{
    for (size_t i = 0; i < len; i++)
    {
        /* Raw NUL: cJSON stops parsing here, so bytes past it would be
         * silently dropped — the truncated and full documents would hash
         * identically. */
        if (input[i] == '\0')
            return BAION_ERR_PARSE;

        if (input[i] == '\\' && i + 5 < len && memcmp(input + i + 1, "u0000", 5) == 0)
        {
            /* Active vs. literal: a run of backslashes pairs off two-at-a-time
             * into literal backslashes; only an ODD-length run leaves the last
             * backslash free to start the backslash-u0000 escape. Even run =
             * literal
             * backslash followed by the text "u0000" — allowed. */
            size_t run = 1;
            while (run <= i && input[i - run] == '\\')
                run++;
            if (run % 2 == 1)
                return BAION_ERR_PARSE;
        }
    }
    return BAION_OK;
}

int baion_reject_duplicate_keys(const cJSON* root)
{
    if (!root)
        return BAION_OK;

    if (cJSON_IsObject(root))
    {
        /* Byte-wise comparison of DECODED sibling key names: cJSON preserves
         * duplicate children and has already decoded escapes into
         * child->string, so backslash-u0061 and "a" collide here even though their
         * raw-text spellings differ. */
        for (const cJSON* a = root->child; a; a = a->next)
        {
            for (const cJSON* b = a->next; b; b = b->next)
            {
                if (a->string && b->string && strcmp(a->string, b->string) == 0)
                    return BAION_ERR_PARSE;
            }
        }
    }

    /* Objects and arrays both chain values through ->child; recurse into
     * either so duplicates inside array elements are caught too. */
    if (cJSON_IsObject(root) || cJSON_IsArray(root))
    {
        for (const cJSON* child = root->child; child; child = child->next)
        {
            if (baion_reject_duplicate_keys(child) != BAION_OK)
                return BAION_ERR_PARSE;
        }
    }

    return BAION_OK;
}

int baion_reject_bom(const char* input, size_t len)
{
    /* cJSON silently skips a leading UTF-8 BOM, so "\xEF\xBB\xBF{...}" and
     * "{...}" would collapse onto one canonical form despite being distinct
     * byte streams — same collision class as U+0000 above. */
    if (len >= 3 && (unsigned char)input[0] == 0xEF && (unsigned char)input[1] == 0xBB
        && (unsigned char)input[2] == 0xBF)
        return BAION_ERR_PARSE;
    return BAION_OK;
}

/* CROSS-LINEAGE CONTRACT: raw control bytes are rejected LEXICALLY in every
 * lineage per RFC 8259 — cJSON alone accepts raw controls inside strings AND
 * skips any byte <= 0x20 between tokens as whitespace, so without this scan C
 * would hash documents the sibling lineages reject. Escaped forms (the
 * backslash-t and backslash-u001F spellings) are escape TEXT — bytes 0x5C
 * 0x74 etc., never a raw byte < 0x20 — so a byte-level check cannot
 * false-positive on them. */
int baion_reject_raw_controls(const char* input, size_t len)
{
    int in_string = 0;
    for (size_t i = 0; i < len; i++)
    {
        unsigned char c = (unsigned char)input[i];

        if (in_string)
        {
            /* Inside a string literal EVERY control byte is illegal — RFC
             * 8259 requires U+0000..U+001F to appear only in escaped form. */
            if (c < 0x20)
                return BAION_ERR_PARSE;
            if (c == '\\')
            {
                /* Escape neutralizes the next byte so an escaped quote
                 * cannot close the string — but that neutralized byte is
                 * still a raw byte and still must not be a control. */
                if (i + 1 < len)
                {
                    i++;
                    if ((unsigned char)input[i] < 0x20)
                        return BAION_ERR_PARSE;
                }
            }
            else if (c == '"')
                in_string = 0;
        }
        else
        {
            if (c == '"')
                in_string = 1;
            /* Between tokens only TAB/LF/CR (and space, >= 0x20) are legal
             * JSON whitespace — cJSON's skip wrongly treats 0x01..0x08,
             * 0x0B, 0x0C, 0x0E..0x1F as skippable too. */
            else if (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D)
                return BAION_ERR_PARSE;
        }
    }
    return BAION_OK;
}

/* CROSS-LINEAGE CONTRACT: input byte streams must be well-formed UTF-8 per
 * RFC 3629 in every lineage — cJSON copies string bytes through unexamined,
 * so C alone would hash documents whose bytes the sibling lineages (C++,
 * Rust, Haskell) reject at decode time. Runs over the WHOLE raw input, not
 * just string interiors: any byte >= 0x80 outside a string is malformed JSON
 * anyway, so whole-stream validation cannot false-positive on legal input. */
int baion_reject_invalid_utf8(const char* input, size_t len)
{
    size_t i = 0;
    while (i < len)
    {
        unsigned char b0 = (unsigned char)input[i];
        size_t cont;               /* continuation bytes required after b0 */
        unsigned char lo = 0x80;   /* legal range for the FIRST continuation */
        unsigned char hi = 0xBF;   /* byte — tightened per lead to exclude   */
                                   /* overlong forms, surrogates, > U+10FFFF */
        if (b0 <= 0x7F)
        {
            i++;
            continue;
        }
        else if (b0 >= 0xC2 && b0 <= 0xDF)
            cont = 1;
        else if (b0 == 0xE0)
        {
            /* E0 80-9F would re-encode U+0000..U+07FF overlong */
            cont = 2;
            lo = 0xA0;
        }
        else if ((b0 >= 0xE1 && b0 <= 0xEC) || b0 == 0xEE || b0 == 0xEF)
            cont = 2;
        else if (b0 == 0xED)
        {
            /* ED A0-BF encodes U+D800..U+DFFF — surrogates are not scalar
             * values and RFC 3629 forbids their encoded form outright. */
            cont = 2;
            hi = 0x9F;
        }
        else if (b0 == 0xF0)
        {
            /* F0 80-8F would re-encode U+0000..U+FFFF overlong */
            cont = 3;
            lo = 0x90;
        }
        else if (b0 >= 0xF1 && b0 <= 0xF3)
            cont = 3;
        else if (b0 == 0xF4)
        {
            /* F4 90+ encodes values above U+10FFFF */
            cont = 3;
            hi = 0x8F;
        }
        else
        {
            /* 0x80-0xBF: continuation byte without a lead.
             * 0xC0/0xC1: leads that can only produce overlong encodings.
             * 0xF5-0xFF: leads for values above U+10FFFF (or not UTF-8). */
            return BAION_ERR_PARSE;
        }

        if (i + cont >= len)
            return BAION_ERR_PARSE; /* truncated sequence at end of input */
        unsigned char b1 = (unsigned char)input[i + 1];
        if (b1 < lo || b1 > hi)
            return BAION_ERR_PARSE;
        for (size_t k = 2; k <= cont; k++)
        {
            unsigned char bk = (unsigned char)input[i + k];
            if (bk < 0x80 || bk > 0xBF)
                return BAION_ERR_PARSE;
        }
        i += cont + 1;
    }
    return BAION_OK;
}

/* CROSS-LINEAGE CONTRACT: escape SHAPE is enforced lexically in every lineage
 * per RFC 8259 §7 — cJSON's parse_hex4 tolerates fewer than 4 hex digits in
 * some malformed inputs (fuzzer round 5: the 5-char "backslash-u-0-0-e-s" and
 * short "backslash-u-d-8-3" forms parsed), so without this scan C would hash
 * documents the sibling lineages reject. Pairing validity of surrogate
 * escapes is a separate concern handled after decode; this scan checks only
 * lexical shape: one of the eight single-char escapes, or 'u' + exactly 4 hex
 * digits. */
int baion_reject_malformed_escapes(const char* input, size_t len)
{
    int in_string = 0;
    for (size_t i = 0; i < len; i++)
    {
        char c = input[i];
        if (!in_string)
        {
            if (c == '"')
                in_string = 1;
            continue;
        }
        if (c == '"')
        {
            in_string = 0;
            continue;
        }
        if (c != '\\')
            continue;

        if (i + 1 >= len)
            return BAION_ERR_PARSE; /* backslash at end of input */
        char e = input[++i];
        switch (e)
        {
        case '"':
        case '\\':
        case '/':
        case 'b':
        case 'f':
        case 'n':
        case 'r':
        case 't':
            break;
        case 'u':
        {
            if (i + 4 >= len)
                return BAION_ERR_PARSE; /* truncated backslash-u escape */
            for (size_t k = 1; k <= 4; k++)
            {
                char h = input[i + k];
                if (!((h >= '0' && h <= '9') || (h >= 'a' && h <= 'f')
                      || (h >= 'A' && h <= 'F')))
                    return BAION_ERR_PARSE;
            }
            i += 4;
            break;
        }
        default:
            return BAION_ERR_PARSE; /* not one of the eight escapes or 'u' */
        }
    }
    return BAION_OK;
}

/* CROSS-LINEAGE CONTRACT: RFC 8259 §6 number SHAPE is enforced lexically in
 * every lineage — cJSON accepts leading zeros ("0635", "-004") and bare
 * trailing dots ("0."), which the sibling lineages reject at parse time.
 * Shape checked here: optional '-', then '0' or [1-9] digits (no leading
 * zeros), then optional '.' followed by AT LEAST one digit. Exponent text is
 * NOT judged here — baion_reject_number_domain already rejects every e/E
 * token, and this scan must not disturb that verdict. */
int baion_reject_number_grammar(const char* input, size_t len)
{
    size_t i = 0;
    while (i < len)
    {
        char c = input[i];

        if (c == '"')
        {
            /* Skip string literals — same escape rule as the sibling scans:
             * a backslash neutralizes the next char so an escaped quote
             * cannot close the string. */
            i++;
            while (i < len && input[i] != '"')
            {
                if (input[i] == '\\' && i + 1 < len)
                    i++;
                i++;
            }
            i++;
            continue;
        }

        if (c == '-' || (c >= '0' && c <= '9'))
        {
            /* Consume the same token alphabet as baion_reject_number_domain
             * so both scans agree on token extent. */
            size_t start = i;
            int has_exp = 0;
            while (i < len)
            {
                char t = input[i];
                if (t >= '0' && t <= '9')
                {
                    /* digit: always part of the token */
                }
                else if (t == '.')
                {
                    /* dot: part of the token (validity judged below) */
                }
                else if (t == 'e' || t == 'E')
                    has_exp = 1;
                else if ((t == '+' || t == '-') && (i == start || has_exp))
                {
                    /* sign: leading minus or exponent sign only */
                }
                else
                    break;
                i++;
            }

            const char* p = input + start;
            const char* q = input + i;
            if (*p == '-')
                p++;
            if (p >= q || *p < '0' || *p > '9')
                return BAION_ERR_PARSE; /* '-' with no integer part */
            if (*p == '0')
            {
                p++;
                if (p < q && *p >= '0' && *p <= '9')
                    return BAION_ERR_PARSE; /* leading zero: 0635, -004, 01. */
            }
            else
            {
                while (p < q && *p >= '0' && *p <= '9')
                    p++;
            }
            if (p < q && *p == '.')
            {
                p++;
                if (p >= q || *p < '0' || *p > '9')
                    return BAION_ERR_PARSE; /* bare trailing dot: 0. / 01. */
                while (p < q && *p >= '0' && *p <= '9')
                    p++;
            }
            /* Any residue must be exponent text — that verdict belongs to
             * baion_reject_number_domain (which rejects all e/E tokens).
             * Non-exponent residue (e.g. a second dot) is shape-invalid. */
            if (p < q && *p != 'e' && *p != 'E')
                return BAION_ERR_PARSE;
            continue;
        }

        i++;
    }
    return BAION_OK;
}

/* CROSS-LINEAGE CONTRACT: the plain-decimal number domain is enforced
 * LEXICALLY over the raw token in every lineage — "100" is in-domain while
 * "1e2" is not, even though both parse to the same double. A post-parse
 * check cannot make that distinction, so this scan must run before cJSON. */
int baion_reject_number_domain(const char* input, size_t len)
{
    /* 2^53: largest magnitude every lineage's double represents exactly for
     * ALL integers up to it. Compared as a digit string — a double compare
     * would round 9007199254740993 down to 2^53 and wave it through. */
    static const char max_safe[] = "9007199254740992";
    const size_t max_safe_len = sizeof(max_safe) - 1;

    size_t i = 0;
    while (i < len)
    {
        char c = input[i];

        if (c == '"')
        {
            /* Skip string literals so digits inside text (e.g. "1e400" as a
             * VALUE) are never mistaken for number tokens. Same escape rule
             * as baion_reject_u0000: a backslash neutralizes the next char,
             * so an escaped quote cannot close the string. */
            i++;
            while (i < len && input[i] != '"')
            {
                if (input[i] == '\\' && i + 1 < len)
                    i++;
                i++;
            }
            i++; /* closing quote */
            continue;
        }

        if (c == '-' || (c >= '0' && c <= '9'))
        {
            /* Number token: consume the JSON number grammar's alphabet.
             * '+'/'-' are only legal at token start or inside an exponent;
             * anywhere else they end the token (invalid JSON — the parser
             * rejects it after this scan). */
            size_t start = i;
            int has_dot = 0;
            int has_exp = 0;
            while (i < len)
            {
                char t = input[i];
                if (t >= '0' && t <= '9')
                {
                    /* digit: always part of the token */
                }
                else if (t == '.')
                    has_dot = 1;
                else if (t == 'e' || t == 'E')
                    has_exp = 1;
                else if ((t == '+' || t == '-') && (i == start || has_exp))
                {
                    /* sign: leading minus or exponent sign only */
                }
                else
                    break;
                i++;
            }

            /* Exponent notation is outside the plain-decimal domain even
             * when the VALUE is in range: "1E2" and "100" must not both
             * canonicalize (the raw spellings differ, the doubles do not). */
            if (has_exp)
                return BAION_ERR_PARSE;

            if (!has_dot)
            {
                /* Integer token: digit-string magnitude compare vs 2^53.
                 * Sign and leading zeros carry no magnitude — strip them,
                 * then longer wins, else lexicographic decides. */
                const char* p = input + start;
                size_t tlen = i - start;
                if (tlen > 0 && *p == '-')
                {
                    p++;
                    tlen--;
                }
                while (tlen > 1 && *p == '0')
                {
                    p++;
                    tlen--;
                }
                if (tlen > max_safe_len
                    || (tlen == max_safe_len && strncmp(p, max_safe, max_safe_len) > 0))
                    return BAION_ERR_PARSE;
            }
            else
            {
                /* Fraction token: the writer's no-exponent reassembly is
                 * only the canonical ECMA-262 spelling for 0 or |v| in
                 * [1e-6, 1e21) — outside that, ToString would switch to
                 * exponent form, so the value is out of domain. strtod
                 * stops at the same delimiter this scan stopped at (or the
                 * caller-guaranteed NUL at input[len]). */
                double v = strtod(input + start, NULL);
                if ((v != 0.0 && fabs(v) < 1e-6) || fabs(v) >= 1e21)
                    return BAION_ERR_PARSE;
            }
            continue;
        }

        i++;
    }
    return BAION_OK;
}

char* baion_canonicalize_json(const cJSON* value)
{
    strbuf_t sb;
    strbuf_init(&sb);
    canonicalize_value(&sb, value);
    if (sb.oom)
    {
        /* Defined failure: a partial canonical string must never reach a
         * hash — free it and report NULL rather than a truncated form. */
        free(sb.data);
        return NULL;
    }
    return sb.data;
}
