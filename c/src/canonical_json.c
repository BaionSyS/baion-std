/* BAION canonical JSON for C — public standalone library.
 *
 * Keys sorted lexicographically at every nesting level, no whitespace,
 * minimal escaping (forward slash / NOT escaped).
 * Numbers: integers as integers, floats as minimal representation. */

#include "baion/canonical_json.h"

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
        /* Float: use %.17g then strip trailing zeros after decimal point */
        char buf[64];
        snprintf(buf, sizeof(buf), "%.17g", d);
        strbuf_appends(sb, buf);
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

char* baion_canonicalize_json(const cJSON* value)
{
    strbuf_t sb;
    strbuf_init(&sb);
    canonicalize_value(&sb, value);
    return sb.data;
}
