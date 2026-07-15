// BAION canonical JSON for C++ — public standalone library.
//
// CRITICAL: This is the byte-identity contract. All language
// implementations must produce identical bytes for the same value.
//
// Rules:
//   - Keys sorted lexicographically at every nesting level
//   - No whitespace between tokens
//   - Numbers: no leading zeros, no trailing decimal, no unnecessary sign
//   - Strings: minimal escaping (only JSON-required characters)
#pragma once

#include <nlohmann/json.hpp>

#include <string>

namespace baion::std_lib
{

// ── Canonical JSON value serialization ────────────────────────
// Recursively serializes any nlohmann::json value to canonical
// form (sorted keys, no whitespace, minimal escaping).
std::string canonicalize_json(const nlohmann::json& j);

} // namespace baion::std_lib
