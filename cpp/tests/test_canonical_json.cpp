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
    // Control char 0x01 escaped as the six-character text \u0001
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

// ── U+0000 rejection: NUL in a string value ───────────────────
// The six-character escape in source text parses to a real NUL
// inside the std::string; the checked path must reject it.
TEST(CanonicalJSON, RejectsNulInStringValue)
{
    nlohmann::json j =
        nlohmann::json::parse("{\"x\":\"a\\u0000b\"}", nullptr, false);
    ASSERT_FALSE(j.is_discarded());

    EXPECT_TRUE(contains_nul(j));

    std::string out;
    EXPECT_FALSE(canonicalize_json_checked(j, out));
    EXPECT_TRUE(out.empty());
}

// ── U+0000 rejection: NUL in an object key ────────────────────
TEST(CanonicalJSON, RejectsNulInObjectKey)
{
    nlohmann::json j =
        nlohmann::json::parse("{\"a\\u0000\":1}", nullptr, false);
    ASSERT_FALSE(j.is_discarded());

    EXPECT_TRUE(contains_nul(j));

    std::string out;
    EXPECT_FALSE(canonicalize_json_checked(j, out));
}

// ── U+0000 rejection: NUL nested deep in arrays/objects ───────
TEST(CanonicalJSON, RejectsNulAtDepth)
{
    nlohmann::json j = nlohmann::json::parse(
        "{\"a\":[1,{\"b\":[\"ok\",\"x\\u0000y\"]}]}", nullptr, false);
    ASSERT_FALSE(j.is_discarded());

    EXPECT_TRUE(contains_nul(j));

    std::string out;
    EXPECT_FALSE(canonicalize_json_checked(j, out));
}

// ── Double-backslash + u0000 is text, not a NUL — allowed ─────
// Source bytes \\u0000 parse to the 6-character text
// backslash + "u0000". No U+0000 character exists, so the
// checked path must accept and canonicalize normally.
TEST(CanonicalJSON, AllowsLiteralBackslashU0000Text)
{
    nlohmann::json j =
        nlohmann::json::parse(R"({"x":"a\\u0000b"})", nullptr, false);
    ASSERT_FALSE(j.is_discarded());

    EXPECT_FALSE(contains_nul(j));

    std::string out;
    EXPECT_TRUE(canonicalize_json_checked(j, out));
    EXPECT_EQ(out, "{\"x\":\"a\\\\u0000b\"}");
}

// ── Duplicate-key rejection: repeat in a flat object ──────────
// The DOM parse silently keeps the last duplicate, so this scan
// runs on the raw text — the duplicate must still be caught.
TEST(CanonicalJSON, RejectsDuplicateKeyFlat)
{
    EXPECT_TRUE(has_duplicate_keys("{\"a\":1,\"a\":2}"));
}

// ── Duplicate-key rejection: repeat inside a nested object ────
TEST(CanonicalJSON, RejectsDuplicateKeyNested)
{
    EXPECT_TRUE(has_duplicate_keys("{\"x\":{\"b\":1,\"b\":2}}"));
}

// ── Duplicate-key rejection: escaped vs. literal key ──────────
// The six-character escape backslash-u0061 decodes to "a", so it collides
// with the literal key "a" — decoded names are what the contract
// compares, not source spellings.
TEST(CanonicalJSON, RejectsDuplicateKeyEscaped)
{
    EXPECT_TRUE(has_duplicate_keys("{\"a\":1,\"\\u0061\":2}"));
}

// ── Duplicate-key rejection: object inside an array ───────────
TEST(CanonicalJSON, RejectsDuplicateKeyInArrayElement)
{
    EXPECT_TRUE(has_duplicate_keys("[{\"k\":1,\"k\":2}]"));
}

// ── Distinct keys pass the duplicate scan ─────────────────────
// Shared prefixes and sibling objects reusing a key at different
// depths are NOT duplicates — only repeats within one object are.
TEST(CanonicalJSON, AllowsDistinctKeys)
{
    EXPECT_FALSE(has_duplicate_keys("{\"aa\":1,\"ab\":2}"));
    EXPECT_FALSE(has_duplicate_keys("{\"b\":1,\"a\":[1,2]}"));
    EXPECT_FALSE(has_duplicate_keys("{\"a\":{\"a\":1},\"b\":{\"a\":2}}"));
}

// ── Number-domain rejection: exponent spelling is lexical ─────
// 100 and 1e2 denote the same value; the contract rejects the
// exponent SPELLING, so the check must see the raw token — the
// SAX number_float callback delivers it.
TEST(CanonicalJSON, RejectsExponentNotation)
{
    EXPECT_TRUE(has_unsupported_number("{\"x\":1e2}"));
    EXPECT_TRUE(has_unsupported_number("{\"x\":1E5}"));
    EXPECT_TRUE(has_unsupported_number("{\"x\":1e-7}"));
    EXPECT_TRUE(has_unsupported_number("{\"x\":2.5E+3}"));
    // Same value, integer spelling — accepted.
    EXPECT_FALSE(has_unsupported_number("{\"x\":100}"));
}

// ── Number-domain rejection: integers beyond +/-2^53 ──────────
// 9007199254740992 (2^53) is the last integer every lineage's
// double holds exactly; one past it in either direction is out.
// The comparison is int64/uint64-exact — no float rounding.
TEST(CanonicalJSON, RejectsIntegersBeyondSafeRange)
{
    EXPECT_TRUE(has_unsupported_number("{\"x\":9007199254740993}"));
    EXPECT_TRUE(has_unsupported_number("{\"x\":-9007199254740993}"));
    EXPECT_FALSE(has_unsupported_number("{\"x\":9007199254740992}"));
    EXPECT_FALSE(has_unsupported_number("{\"x\":-9007199254740992}"));
}

// ── Number-domain rejection: integers past uint64 ──────────────
// nlohmann routes integers that overflow 64 bits to number_float,
// bypassing the integer callbacks — the scanner must recognize a
// dotless raw token as an integer and judge it by digit string,
// not by the fraction magnitude window (1e20 < 1e21 would pass).
TEST(CanonicalJSON, RejectsIntegersBeyondUint64)
{
    EXPECT_TRUE(has_unsupported_number(
        "{\"x\":100000000000000000000}"));
    EXPECT_TRUE(has_unsupported_number(
        "{\"x\":-100000000000000000000}"));
    // 2^64 + 1: just past uint64, well past 2^53.
    EXPECT_TRUE(has_unsupported_number(
        "{\"x\":18446744073709551617}"));
    // A genuine fraction token (has '.') near the top of the window
    // stays on the existing magnitude check and remains accepted.
    EXPECT_FALSE(has_unsupported_number(
        "{\"x\":100000000000000000000.5}"));
}

// ── Number-domain rejection: out-of-range fractions ───────────
// Below 1e-6 (nonzero) or at/above 1e21 lineage formatters flip
// to scientific notation and diverge; the domain excludes them.
TEST(CanonicalJSON, RejectsOutOfRangeFractions)
{
    EXPECT_TRUE(has_unsupported_number("{\"x\":0.0000001}"));
    // Boundary stays in: exactly 1e-6 written plainly is supported.
    EXPECT_FALSE(has_unsupported_number("{\"x\":0.000001}"));
    EXPECT_FALSE(has_unsupported_number("{\"x\":0.1}"));
    EXPECT_FALSE(has_unsupported_number("{\"x\":0.0}"));
    EXPECT_FALSE(has_unsupported_number("{\"x\":-0.0}"));
}

// ── Number-domain rejection: bad number at depth ──────────────
TEST(CanonicalJSON, RejectsUnsupportedNumberAtDepth)
{
    EXPECT_TRUE(has_unsupported_number("{\"a\":[1,{\"b\":[2,1e2]}]}"));
    EXPECT_FALSE(has_unsupported_number(
        "{\"nested\":{\"y\":[true,false,null],\"x\":0.5},\"arr\":[]}"));
}

// ── UTF-8 BOM rejection: leading BOM caught, elsewhere ignored ─
// RFC 8259 §8.1 forbids adding a BOM; nlohmann would silently skip
// it, so the raw-byte check must fire before any parse.
TEST(CanonicalJSON, RejectsLeadingUtf8Bom)
{
    EXPECT_TRUE(has_utf8_bom("\xEF\xBB\xBF{\"a\":1}"));
    EXPECT_TRUE(has_utf8_bom("\xEF\xBB\xBF"));
    EXPECT_FALSE(has_utf8_bom("{\"a\":1}"));
    // Too short to hold a BOM, and prefixes of one are not a BOM.
    EXPECT_FALSE(has_utf8_bom(""));
    EXPECT_FALSE(has_utf8_bom("\xEF\xBB"));
    // BOM bytes past position 0 are ordinary content for the parser.
    EXPECT_FALSE(has_utf8_bom(" \xEF\xBB\xBF"));
}

// ── Checked path matches unchecked path on clean input ────────
TEST(CanonicalJSON, CheckedMatchesUncheckedOnCleanInput)
{
    nlohmann::json j =
        nlohmann::json::parse(R"({"b":1,"a":[1,2]})", nullptr, false);
    ASSERT_FALSE(j.is_discarded());

    std::string out;
    ASSERT_TRUE(canonicalize_json_checked(j, out));
    EXPECT_EQ(out, canonicalize_json(j));
    EXPECT_EQ(out, "{\"a\":[1,2],\"b\":1}");
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

// ── Floats: shortest round-trip digits, plain positional layout ──
// Each case: shortest decimal string that roundtrips to the same double,
// reassembled WITHOUT exponent notation, per RFC 8785 / ECMA-262
// §7.1.12.1. The old nlohmann dump() path printed 0.00001 as "1e-05"
// and 1e20-scale values as "1e+20", diverging from every other lineage.
TEST(CanonicalJSON, FloatShortestRoundtripPlainDecimal)
{
    static const struct
    {
        double v;
        const char* expect;
    } cases[] = {
        {0.1, "0.1"},
        {123.456, "123.456"},
        {0.5, "0.5"},
        {0.001, "0.001"},
        {0.0001, "0.0001"},
        {0.000123, "0.000123"},
        {0.00001, "0.00001"},
        {0.000001, "0.000001"}, // n = -5 boundary: "0." + 5 zeros + D
        {1e16, "10000000000000000"}, // dl < n: zero-padded, no dot
        {9007199254740992.0,
         "9007199254740992"}, // 2^53: above the int64 branch cutoff
        // 1e20 + 0.5 rounds to the 21-digit integer double 1e20: exercises
        // the n = 21 top of the zero-padding branch (domain ceiling).
        {100000000000000000000.5, "100000000000000000000"},
        {-2.5, "-2.5"},
        {-0.375, "-0.375"},
        {1.0, "1"},  // integer-valued keeps no-trailing-".0" behavior
        {-0.0, "0"}, // zero (incl. negative zero) always emits exactly "0"
    };

    for (const auto& c : cases)
    {
        nlohmann::json n = c.v;
        ASSERT_TRUE(n.is_number_float())
            << "case must be float-tagged: " << c.expect;
        EXPECT_EQ(canonicalize_json(n), c.expect);
    }
}
