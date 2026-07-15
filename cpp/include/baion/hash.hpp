// BAION SHA-256 for C++ — public standalone library.
//
// SHA-256 is FIPS 180-4 (vendored here as picosha2). Must produce
// identical results across all language implementations.
#pragma once

#include <string>

namespace baion::std_lib
{

// Compute the lowercase-hex SHA-256 digest of a byte string.
// Used to hash canonical JSON bytes into content-addressed keys.
std::string sha256_hex(const std::string& bytes);

} // namespace baion::std_lib
