// BAION SHA-256 for C++ — public standalone library.

#include "baion/hash.hpp"

#include "picosha2.h"

namespace baion::std_lib
{

// CROSS-LINEAGE CONTRACT: identical byte input must produce identical
// digest hex across all language implementations. SHA-256 is FIPS 180-4
// (vendored here as picosha2; native libraries elsewhere). Divergence
// breaks canonical-hash parity across implementations.
std::string sha256_hex(const std::string& bytes)
{
    return picosha2::hash256_hex_string(bytes);
}

} // namespace baion::std_lib
