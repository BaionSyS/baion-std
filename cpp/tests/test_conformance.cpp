// BAION canonical JSON for C++ — cross-implementation conformance tests.
//
// Verifies byte-identical output against the shared fixture
// conformance_reference.json. Fixture inputs are parsed at runtime and
// canonicalized through the public API, so the expected strings live in
// ONE place shared by every language implementation.

#include "baion/canonical_json.hpp"
#include "baion/hash.hpp"

#include <gtest/gtest.h>

#include <fstream>
#include <sstream>
#include <string>

#ifndef FIXTURE_PATH
#error "FIXTURE_PATH must point at conformance_reference.json"
#endif

using namespace baion::std_lib;

namespace
{

const nlohmann::json& fixture()
{
    static nlohmann::json f = []
    {
        std::ifstream in(FIXTURE_PATH, std::ios::binary);
        std::ostringstream buf;
        buf << in.rdbuf();
        // Non-throwing parse (suite is built with -fno-exceptions).
        return nlohmann::json::parse(buf.str(), nullptr, false);
    }();
    return f;
}

// Canonicalize the fixture object at <base>, compare byte-for-byte against
// the reference string at <base>_canonical_json, then hash the canonical
// bytes and compare against <base>_sha256_hex.
void check_document(const std::string& base)
{
    const nlohmann::json& f = fixture();
    ASSERT_FALSE(f.is_discarded()) << "cannot read/parse fixture " << FIXTURE_PATH;
    ASSERT_TRUE(f.contains(base));
    ASSERT_TRUE(f.contains(base + "_canonical_json"));
    ASSERT_TRUE(f.contains(base + "_sha256_hex"));

    const std::string canonical = canonicalize_json(f.at(base));
    EXPECT_EQ(canonical, f.at(base + "_canonical_json").get<std::string>());
    EXPECT_EQ(sha256_hex(canonical), f.at(base + "_sha256_hex").get<std::string>());
}

} // namespace

TEST(Conformance, ReferenceDocument)
{
    check_document("reference_document");
}

TEST(Conformance, ReferenceDocumentUnicode)
{
    check_document("reference_document_unicode");
}

TEST(Conformance, ReferenceDocumentEdges)
{
    check_document("reference_document_edges");
}

TEST(Conformance, Sha256ReferenceVector)
{
    const nlohmann::json& f = fixture();
    ASSERT_FALSE(f.is_discarded());
    ASSERT_TRUE(f.contains("reference_sha256_input"));
    ASSERT_TRUE(f.contains("reference_sha256_hex"));

    EXPECT_EQ(sha256_hex(f.at("reference_sha256_input").get<std::string>()),
              f.at("reference_sha256_hex").get<std::string>());
}

// Integer-valued floats canonicalize without trailing decimal per
// RFC 8785 / ECMA-262. Built programmatically (not from the fixture)
// because the fixture cannot express float-tagged 1.0 vs int 1.
TEST(Conformance, IntegerValuedFloats)
{
    const nlohmann::json& f = fixture();
    ASSERT_FALSE(f.is_discarded());
    ASSERT_TRUE(f.contains("reference_integer_valued_floats_canonical_json"));

    nlohmann::json v = nlohmann::json::object();
    v["frac"] = 1.5;
    v["neg"] = -7.0;
    v["vals"] = nlohmann::json::array({1.0, 2.0, 3.0});
    ASSERT_TRUE(v["vals"][0].is_number_float());
    ASSERT_TRUE(v["neg"].is_number_float());

    EXPECT_EQ(canonicalize_json(v),
              f.at("reference_integer_valued_floats_canonical_json").get<std::string>());
}
