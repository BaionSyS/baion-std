/* BAION canonical JSON for C — public standalone library.
 *
 * Keys sorted lexicographically at every nesting level, no whitespace,
 * minimal escaping (forward slash / NOT escaped).
 * Numbers: integers as integers, floats as minimal representation. */

#include "baion/canonical_json.h"

#include "baion/public_types.h"

#include <cJSON.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Dynamic string buffer */
typedef struct
{
    char* data;
    size_t len;
    size_t cap;
} strbuf_t;

static void strbuf_init(strbuf_t* sb)
{
    sb->cap = 512;
    sb->data = (char*)malloc(sb->cap);
    sb->len = 0;
    sb->data[0] = '\0';
}

static void strbuf_ensure(strbuf_t* sb, size_t extra)
{
    if (sb->len + extra + 1 > sb->cap)
    {
        while (sb->len + extra + 1 > sb->cap)
            sb->cap *= 2;
        sb->data = (char*)realloc(sb->data, sb->cap);
    }
}

static void strbuf_append(strbuf_t* sb, const char* s, size_t n)
{
    strbuf_ensure(sb, n);
    memcpy(sb->data + sb->len, s, n);
    sb->len += n;
    sb->data[sb->len] = '\0';
}

static void strbuf_appendc(strbuf_t* sb, char c)
{
    strbuf_ensure(sb, 1);
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
    if (d == (double)(long long)d && fabs(d) < 1e15)
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
    return sb.data;
}
