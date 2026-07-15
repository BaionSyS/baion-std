/* BAION canonical JSON for C — cross-implementation conformance tests.
   Verifies byte-identical output against the shared fixture
   conformance_reference.json. Fixture inputs are parsed at runtime and
   canonicalized through the public API, so the expected strings live in
   ONE place shared by every language implementation. */

#include "baion/canonical_json.h"
#include "baion/sha256.h"
#include "test_util.h"

#include <cJSON.h>
#include <stdlib.h>

#ifndef FIXTURE_PATH
#error "FIXTURE_PATH must point at conformance_reference.json"
#endif

static cJSON* g_fixture = NULL;

static char* read_file(const char* path)
{
    FILE* f = fopen(path, "rb");
    if (!f)
        return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char* buf = (char*)malloc((size_t)n + 1);
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    buf[got] = '\0';
    return buf;
}

static void hex32(const uint8_t hash[32], char hex[65])
{
    for (int i = 0; i < 32; i++)
        sprintf(hex + i * 2, "%02x", hash[i]);
    hex[64] = '\0';
}

/* Canonicalize the fixture object at <base>, compare byte-for-byte against
   the reference string at <base>_canonical_json, then hash the canonical
   bytes and compare against <base>_sha256_hex. */
static void check_document(const char* base)
{
    char key[128];

    const cJSON* input = cJSON_GetObjectItemCaseSensitive(g_fixture, base);
    snprintf(key, sizeof(key), "%s_canonical_json", base);
    const cJSON* expected_json = cJSON_GetObjectItemCaseSensitive(g_fixture, key);
    snprintf(key, sizeof(key), "%s_sha256_hex", base);
    const cJSON* expected_hex = cJSON_GetObjectItemCaseSensitive(g_fixture, key);

    ASSERT_TRUE(input != NULL);
    ASSERT_TRUE(cJSON_IsString(expected_json));
    ASSERT_TRUE(cJSON_IsString(expected_hex));

    char* json = baion_canonicalize_json(input);
    ASSERT_STR_EQ(json, expected_json->valuestring);

    uint8_t hash[32];
    char hex[65];
    baion_sha256((const uint8_t*)json, strlen(json), hash);
    hex32(hash, hex);
    ASSERT_STR_EQ(hex, expected_hex->valuestring);

    free(json);
}

static void test_conformance_reference_document(void)
{
    check_document("reference_document");
}

static void test_conformance_reference_document_unicode(void)
{
    check_document("reference_document_unicode");
}

static void test_conformance_reference_document_edges(void)
{
    check_document("reference_document_edges");
}

static void test_conformance_sha256_hex(void)
{
    const cJSON* input = cJSON_GetObjectItemCaseSensitive(g_fixture, "reference_sha256_input");
    const cJSON* expected = cJSON_GetObjectItemCaseSensitive(g_fixture, "reference_sha256_hex");
    ASSERT_TRUE(cJSON_IsString(input));
    ASSERT_TRUE(cJSON_IsString(expected));

    uint8_t hash[32];
    baion_sha256(
        (const uint8_t*)input->valuestring, strlen(input->valuestring), hash);

    char hex[65];
    hex32(hash, hex);

    ASSERT_STR_EQ(hex, expected->valuestring);
}

/* Test integer-valued floats: canonicalize without trailing decimal.
   Fixed 2026-05-04: earlier float formatting diverged from RFC 8785.
   cJSON stores all numbers as double — the
   canonicalizer must detect integer-valued doubles and emit them without
   ".0" per RFC 8785 / ECMA-262. Built programmatically (not from the
   fixture) because the fixture cannot express float-tagged 1.0 vs int 1. */
static void test_conformance_integer_valued_floats(void)
{
    const cJSON* expected = cJSON_GetObjectItemCaseSensitive(
        g_fixture, "reference_integer_valued_floats_canonical_json");
    ASSERT_TRUE(cJSON_IsString(expected));

    cJSON* obj = cJSON_CreateObject();
    cJSON_AddNumberToObject(obj, "frac", 1.5);
    cJSON_AddNumberToObject(obj, "neg", -7.0);
    cJSON* vals = cJSON_CreateDoubleArray((const double[]){1.0, 2.0, 3.0}, 3);
    cJSON_AddItemToObject(obj, "vals", vals);

    char* json = baion_canonicalize_json(obj);
    ASSERT_STR_EQ(json, expected->valuestring);
    free(json);
    cJSON_Delete(obj);
}

int main(void)
{
    printf("test_conformance:\n");

    char* raw = read_file(FIXTURE_PATH);
    if (!raw)
    {
        printf("  FATAL: cannot read fixture %s\n", FIXTURE_PATH);
        return 1;
    }
    g_fixture = cJSON_Parse(raw);
    free(raw);
    if (!g_fixture)
    {
        printf("  FATAL: cannot parse fixture %s\n", FIXTURE_PATH);
        return 1;
    }

    RUN_TEST(test_conformance_reference_document);
    RUN_TEST(test_conformance_reference_document_unicode);
    RUN_TEST(test_conformance_reference_document_edges);
    RUN_TEST(test_conformance_sha256_hex);
    RUN_TEST(test_conformance_integer_valued_floats);
    TEST_SUMMARY();

    cJSON_Delete(g_fixture);
    return _test_failed;
}
