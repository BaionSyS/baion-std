/* BAION STD C — Canonical JSON Tests (public cut: generic value canonicalization) */

#include "baion/canonical_json.h"
#include "baion/public_types.h"
#include "test_util.h"

#include <cJSON.h>
#include <stdlib.h>
#include <string.h>

static void test_nested_key_sorting(void)
{
    cJSON* obj = cJSON_CreateObject();
    cJSON* inner = cJSON_CreateObject();
    cJSON_AddStringToObject(inner, "zebra", "z");
    cJSON_AddStringToObject(inner, "alpha", "a");
    cJSON_AddStringToObject(inner, "middle", "m");
    cJSON_AddItemToObject(obj, "z_outer", inner);
    cJSON_AddNumberToObject(obj, "a_outer", 1);

    char* json = baion_canonicalize_json(obj);
    ASSERT_STR_EQ(json,
                  "{\"a_outer\":1,\"z_outer\":{\"alpha\":\"a\",\"middle\":\"m\",\"zebra\":\"z\"}}");
    free(json);
    cJSON_Delete(obj);
}

static void test_string_escaping(void)
{
    cJSON* s;
    char* json;

    /* Quote and backslash */
    s = cJSON_CreateString("a\"b\\c");
    json = baion_canonicalize_json(s);
    ASSERT_STR_EQ(json, "\"a\\\"b\\\\c\"");
    free(json);
    cJSON_Delete(s);

    /* Control characters */
    s = cJSON_CreateString("a\nb\tc");
    json = baion_canonicalize_json(s);
    ASSERT_STR_EQ(json, "\"a\\nb\\tc\"");
    free(json);
    cJSON_Delete(s);

    /* Forward slash NOT escaped */
    s = cJSON_CreateString("a/b");
    json = baion_canonicalize_json(s);
    ASSERT_STR_EQ(json, "\"a/b\"");
    free(json);
    cJSON_Delete(s);
}

static void test_number_formats(void)
{
    char* json;

    /* Integer */
    cJSON* n = cJSON_CreateNumber(42);
    json = baion_canonicalize_json(n);
    ASSERT_STR_EQ(json, "42");
    free(json);
    cJSON_Delete(n);

    /* Zero */
    n = cJSON_CreateNumber(0);
    json = baion_canonicalize_json(n);
    ASSERT_STR_EQ(json, "0");
    free(json);
    cJSON_Delete(n);

    /* Negative */
    n = cJSON_CreateNumber(-7);
    json = baion_canonicalize_json(n);
    ASSERT_STR_EQ(json, "-7");
    free(json);
    cJSON_Delete(n);
}

static void test_array_order_preserved(void)
{
    cJSON* arr = cJSON_CreateArray();
    cJSON_AddItemToArray(arr, cJSON_CreateNumber(3));
    cJSON_AddItemToArray(arr, cJSON_CreateNumber(1));
    cJSON_AddItemToArray(arr, cJSON_CreateNumber(2));

    char* json = baion_canonicalize_json(arr);
    ASSERT_STR_EQ(json, "[3,1,2]");
    free(json);
    cJSON_Delete(arr);
}

static void test_empty_payload(void)
{
    cJSON* obj = cJSON_CreateObject();
    char* json = baion_canonicalize_json(obj);
    ASSERT_STR_EQ(json, "{}");
    free(json);
    cJSON_Delete(obj);
}

static void test_booleans(void)
{
    cJSON* obj = cJSON_CreateObject();
    cJSON_AddBoolToObject(obj, "b", 0);
    cJSON_AddBoolToObject(obj, "a", 1);
    char* json = baion_canonicalize_json(obj);
    ASSERT_STR_EQ(json, "{\"a\":true,\"b\":false}");
    free(json);
    cJSON_Delete(obj);
}

static void test_u0000_rejection(void)
{
    /* Active escape in a value: cJSON would decode it to a NUL byte and
     * truncate the string, so the pre-parse scan must reject. */
    const char* val_escape = "{\"x\":\"a\\u0000b\"}";
    ASSERT_INT_EQ(baion_reject_u0000(val_escape, strlen(val_escape)), BAION_ERR_PARSE);

    /* Active escape in a key */
    const char* key_escape = "{\"a\\u0000\":1}";
    ASSERT_INT_EQ(baion_reject_u0000(key_escape, strlen(key_escape)), BAION_ERR_PARSE);

    /* Even backslash run = literal backslash + the text "u0000": allowed */
    const char* literal = "{\"x\":\"a\\\\u0000b\"}";
    ASSERT_INT_EQ(baion_reject_u0000(literal, strlen(literal)), BAION_OK);

    /* Odd run of three: literal backslash THEN an active escape: reject */
    const char* triple = "{\"x\":\"a\\\\\\u0000b\"}";
    ASSERT_INT_EQ(baion_reject_u0000(triple, strlen(triple)), BAION_ERR_PARSE);

    /* Raw 0x00 byte anywhere in the input: reject */
    const char raw_nul[] = {'{', '"', 'x', '"', ':', '\0', '1', '}'};
    ASSERT_INT_EQ(baion_reject_u0000(raw_nul, sizeof(raw_nul)), BAION_ERR_PARSE);

    /* Clean document: passes */
    const char* clean = "{\"x\":\"a b\"}";
    ASSERT_INT_EQ(baion_reject_u0000(clean, strlen(clean)), BAION_OK);
}

/* Parse text with cJSON, run the duplicate-key walk on the decoded tree,
 * free the tree. Returns the walk's verdict; -1 flags a parse failure so the
 * assert lines below surface it instead of a misleading OK/ERR. */
static int dup_check(const char* text)
{
    cJSON* root = cJSON_Parse(text);
    if (!root)
        return -1;
    int rc = baion_reject_duplicate_keys(root);
    cJSON_Delete(root);
    return rc;
}

static void test_duplicate_key_rejection(void)
{
    /* Plain duplicate at top level: reject */
    ASSERT_INT_EQ(dup_check("{\"a\":1,\"a\":2}"), BAION_ERR_PARSE);

    /* Duplicate nested one object deep: reject */
    ASSERT_INT_EQ(dup_check("{\"x\":{\"b\":1,\"b\":2}}"), BAION_ERR_PARSE);

    /* Escaped-form duplicate: backslash-u0061 decodes to "a", so the DECODED
     * names collide even though the raw spellings differ: reject */
    ASSERT_INT_EQ(dup_check("{\"a\":1,\"\\u0061\":2}"), BAION_ERR_PARSE);

    /* Duplicate inside an object inside an array: reject */
    ASSERT_INT_EQ(dup_check("[{\"c\":1,\"c\":2}]"), BAION_ERR_PARSE);

    /* Distinct keys sharing a prefix: allowed */
    ASSERT_INT_EQ(dup_check("{\"aa\":1,\"ab\":2}"), BAION_OK);

    /* Distinct keys with an array value: allowed */
    ASSERT_INT_EQ(dup_check("{\"b\":1,\"a\":[1,2]}"), BAION_OK);
}

static void test_float_shortest_roundtrip(void)
{
    /* Each case: shortest decimal string that roundtrips to the same double,
     * positional layout (no exponent), per RFC 8785 / ECMA-262. The old
     * %.17g path printed 0.1 as "0.10000000000000001", diverging from every
     * other lineage. */
    static const struct
    {
        double v;
        const char* expect;
    } cases[] = {
        {0.1, "0.1"},
        {123.456, "123.456"},
        {0.5, "0.5"},
        {0.000001, "0.000001"},         /* n = -5 boundary: "0." + 5 zeros + D */
        {1e16, "10000000000000000"},    /* dl < n: zero-padded, no dot */
        {9007199254740992.0, "9007199254740992"}, /* 2^53: above %lld branch cutoff */
        {-2.5, "-2.5"},
        {1.0, "1"},   /* integer-valued keeps no-trailing-".0" behavior */
        {-0.0, "0"},  /* zero (incl. negative zero) always emits exactly "0" */
    };

    for (size_t k = 0; k < sizeof(cases) / sizeof(cases[0]); k++)
    {
        cJSON* n = cJSON_CreateNumber(cases[k].v);
        char* json = baion_canonicalize_json(n);
        ASSERT_STR_EQ(json, cases[k].expect);
        free(json);
        cJSON_Delete(n);
    }
}

static void test_number_domain_rejection(void)
{
    /* Exponent notation: out of domain even when the value is in range —
     * the scan is LEXICAL, "1e2" and "100" must not both canonicalize. */
    const char* exp_lower = "{\"x\":1e2}";
    ASSERT_INT_EQ(baion_reject_number_domain(exp_lower, strlen(exp_lower)), BAION_ERR_PARSE);
    const char* exp_upper = "{\"x\":1E5}";
    ASSERT_INT_EQ(baion_reject_number_domain(exp_upper, strlen(exp_upper)), BAION_ERR_PARSE);
    const char* exp_neg = "{\"x\":1e-7}";
    ASSERT_INT_EQ(baion_reject_number_domain(exp_neg, strlen(exp_neg)), BAION_ERR_PARSE);
    const char* exp_huge = "{\"x\":1e400}";
    ASSERT_INT_EQ(baion_reject_number_domain(exp_huge, strlen(exp_huge)), BAION_ERR_PARSE);

    /* Same value spelled plainly: allowed */
    const char* plain = "{\"x\":100}";
    ASSERT_INT_EQ(baion_reject_number_domain(plain, strlen(plain)), BAION_OK);

    /* Integer magnitude: 2^53 itself stays in-domain; 2^53 + 1 is rejected
     * in both signs (a double compare would round it down and miss it). */
    const char* at_limit = "{\"x\":9007199254740992}";
    ASSERT_INT_EQ(baion_reject_number_domain(at_limit, strlen(at_limit)), BAION_OK);
    const char* over_limit = "{\"x\":9007199254740993}";
    ASSERT_INT_EQ(baion_reject_number_domain(over_limit, strlen(over_limit)), BAION_ERR_PARSE);
    const char* neg_over = "{\"x\":-9007199254740993}";
    ASSERT_INT_EQ(baion_reject_number_domain(neg_over, strlen(neg_over)), BAION_ERR_PARSE);

    /* Longer digit string: rejected by length before any lexicographic step */
    const char* long_int = "{\"x\":100000000000000000000}";
    ASSERT_INT_EQ(baion_reject_number_domain(long_int, strlen(long_int)), BAION_ERR_PARSE);

    /* Fraction magnitude: |v| must be 0 or in [1e-6, 1e21) */
    const char* tiny = "{\"x\":0.0000001}";
    ASSERT_INT_EQ(baion_reject_number_domain(tiny, strlen(tiny)), BAION_ERR_PARSE);
    const char* micro = "{\"x\":0.000001}";
    ASSERT_INT_EQ(baion_reject_number_domain(micro, strlen(micro)), BAION_OK);
    const char* huge_frac = "{\"x\":1000000000000000000000.5}";
    ASSERT_INT_EQ(baion_reject_number_domain(huge_frac, strlen(huge_frac)), BAION_ERR_PARSE);
    const char* zero_frac = "{\"x\":0.0}";
    ASSERT_INT_EQ(baion_reject_number_domain(zero_frac, strlen(zero_frac)), BAION_OK);

    /* Number-shaped text inside string literals is NOT a number token —
     * including behind an escaped quote, which must not close the string. */
    const char* in_string = "{\"x\":\"1e400\"}";
    ASSERT_INT_EQ(baion_reject_number_domain(in_string, strlen(in_string)), BAION_OK);
    const char* esc_quote = "{\"a\\\"e\":\"9E99\",\"x\":2}";
    ASSERT_INT_EQ(baion_reject_number_domain(esc_quote, strlen(esc_quote)), BAION_OK);
}

static void test_bom_rejection(void)
{
    /* Leading UTF-8 BOM: cJSON would silently skip it, collapsing the
     * BOM-prefixed and BOM-free documents onto one hash — reject. */
    const char* bom_doc = "\xEF\xBB\xBF{\"a\":1}";
    ASSERT_INT_EQ(baion_reject_bom(bom_doc, strlen(bom_doc)), BAION_ERR_PARSE);

    /* Same document without the BOM: allowed */
    const char* clean = "{\"a\":1}";
    ASSERT_INT_EQ(baion_reject_bom(clean, strlen(clean)), BAION_OK);

    /* BOM bytes NOT at the very start are just string content: allowed */
    const char* interior = "{\"a\":\"\xEF\xBB\xBF\"}";
    ASSERT_INT_EQ(baion_reject_bom(interior, strlen(interior)), BAION_OK);
}

int main(void)
{
    printf("test_canonical_json:\n");
    RUN_TEST(test_nested_key_sorting);
    RUN_TEST(test_string_escaping);
    RUN_TEST(test_number_formats);
    RUN_TEST(test_array_order_preserved);
    RUN_TEST(test_empty_payload);
    RUN_TEST(test_booleans);
    RUN_TEST(test_u0000_rejection);
    RUN_TEST(test_duplicate_key_rejection);
    RUN_TEST(test_float_shortest_roundtrip);
    RUN_TEST(test_number_domain_rejection);
    RUN_TEST(test_bom_rejection);
    TEST_SUMMARY();
    return _test_failed;
}
