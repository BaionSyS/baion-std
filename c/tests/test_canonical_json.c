/* BAION STD C — Canonical JSON Tests (public cut: generic value canonicalization) */

#include "baion/canonical_json.h"
#include "test_util.h"

#include <cJSON.h>
#include <stdlib.h>

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

int main(void)
{
    printf("test_canonical_json:\n");
    RUN_TEST(test_nested_key_sorting);
    RUN_TEST(test_string_escaping);
    RUN_TEST(test_number_formats);
    RUN_TEST(test_array_order_preserved);
    RUN_TEST(test_empty_payload);
    RUN_TEST(test_booleans);
    TEST_SUMMARY();
    return _test_failed;
}
