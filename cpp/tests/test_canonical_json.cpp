// BAION canonical JSON for C++ — canonicalizer tests.
//
// These tests define the contract. All language implementations
// must produce the same bytes for the same input.

#include "baion/canonical_json.hpp"

#include <gtest/gtest.h>

using namespace baion::std_lib;

// ── Key sorting: deeply nested value ──────────────────────────
TEST(CanonicalJSON, DeepNestedKeySorting)
{
    nlohmann::json deep;
    deep["z"] = nlohmann::json::object();
    deep["z"]["m"] = 1;
    deep["z"]["a"] = 2;
    deep["a"] = nlohmann::json::object();
    deep["a"]["z"] = nlohmann::json::object();
    deep["a"]["z"]["b"] = true;
    deep["a"]["z"]["a"] = false;
    deep["a"]["a"] = "first";

    std::string result = canonicalize_json(deep);
    std::string expected =
        "{\"a\":{\"a\":\"first\",\"z\":{\"a\":false,\"b\":true}},\"z\":{\"a\":2,\"m\":1}}";
    EXPECT_EQ(result, expected);
}

// ── String escaping: minimal escaping only ────────────────────
TEST(CanonicalJSON, MinimalStringEscaping)
{
    nlohmann::json j;
    j["quote"] = "he said \"hello\"";
    j["backslash"] = "path\\to\\file";
    j["newline"] = "line1\nline2";
    j["tab"] = "col1\tcol2";
    j["control"] = std::string(1, '\x01');
    j["normal"] = "just ascii / and more";

    std::string result = canonicalize_json(j);

    // Forward slash is NOT escaped (minimal escaping)
    EXPECT_NE(result.find("just ascii / and more"), std::string::npos);
    // Control char 0x01 escaped as 
    EXPECT_NE(result.find("\\u0001"), std::string::npos);
    // Quote escaped
    EXPECT_NE(result.find("\\\"hello\\\""), std::string::npos);
}

// ── Non-ASCII UTF-8 passes through unescaped ──────────────────
// Minimal escaping means bytes >= 0x20 other than " and \ are
// emitted verbatim — including multi-byte UTF-8 sequences.
TEST(CanonicalJSON, Utf8PassThrough)
{
    nlohmann::json j;
    j["a"] = "\xC3\xA9"; // é as raw UTF-8

    std::string result = canonicalize_json(j);
    EXPECT_EQ(result, "{\"a\":\"\xC3\xA9\"}");
}

// ── Number serialization ──────────────────────────────────────
TEST(CanonicalJSON, NumberSerialization)
{
    nlohmann::json j;
    j["positive"] = 42;
    j["zero"] = 0;
    j["negative"] = -7;

    std::string result = canonicalize_json(j);
    EXPECT_NE(result.find("\"negative\":-7"), std::string::npos);
    EXPECT_NE(result.find("\"positive\":42"), std::string::npos);
    EXPECT_NE(result.find("\"zero\":0"), std::string::npos);
}

// ── Empty object → {} ─────────────────────────────────────────
TEST(CanonicalJSON, EmptyObject)
{
    nlohmann::json j = nlohmann::json::object();
    EXPECT_EQ(canonicalize_json(j), "{}");
}

// ── Array ordering preserved ──────────────────────────────────
TEST(CanonicalJSON, ArrayOrderPreserved)
{
    nlohmann::json j = nlohmann::json::array({3, 1, 2});
    EXPECT_EQ(canonicalize_json(j), "[3,1,2]");
}

// ── Integer-valued floats canonicalize without trailing decimal ──
// Build the value with explicit float-tagged
// numbers (nlohmann::json::value_t::number_float) so the canonicalizer sees
// them as floats, not integers, in the native type system. Output must
// strip ".0" from integer-valued floats per RFC 8785 / ECMA-262.
TEST(CanonicalJSON, IntegerValuedFloats)
{
    nlohmann::json v = nlohmann::json::object();
    v["frac"] = 1.5;
    v["neg"] = -7.0;
    v["vals"] = nlohmann::json::array({1.0, 2.0, 3.0});

    // Verify nlohmann tagged each as float (otherwise the test would not
    // exercise the float-formatting path at all).
    ASSERT_TRUE(v["vals"][0].is_number_float()) << "vals[0] must be float-tagged";
    ASSERT_TRUE(v["neg"].is_number_float()) << "neg must be float-tagged";

    std::string result = canonicalize_json(v);
    std::string expected = "{\"frac\":1.5,\"neg\":-7,\"vals\":[1,2,3]}";

    EXPECT_EQ(result, expected);
}
