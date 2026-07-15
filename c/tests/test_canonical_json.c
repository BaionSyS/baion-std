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
    TEST_SUMMARY();
    return _test_failed;
}
