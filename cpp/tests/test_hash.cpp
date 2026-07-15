// BAION SHA-256 for C++ — hashing tests.
//
// All language implementations must produce the same digest for the
// same input.

#include "baion/hash.hpp"

#include <gtest/gtest.h>

using namespace baion::std_lib;

// ── SHA-256 hex: FIPS 180-4 known-answer vectors ──────────────
TEST(Hash, Sha256HexKnownVectors)
{
    // NIST FIPS 180-4 example vector
    EXPECT_EQ(sha256_hex("abc"),
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    // Empty-string digest
    EXPECT_EQ(sha256_hex(""),
              "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
}

// ── SHA-256 hex: shared conformance reference ─────────────────
// Matches reference_sha256_input / reference_sha256_hex in
// conformance_reference.json.
TEST(Hash, Sha256HexSharedReferenceVector)
{
    EXPECT_EQ(sha256_hex("baion-std cross-lineage conformance"),
              "cb812203aaf4e4f8f63b242a5814fe036c7346a85efa961ff85a207596e4f451");
}
