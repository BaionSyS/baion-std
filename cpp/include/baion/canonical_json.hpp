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

// ── U+0000 rejection scan ──────────────────────────────────────
// CROSS-LINEAGE CONTRACT: any input whose object keys or string
// values (at any depth) contain U+0000 must be rejected before
// canonicalization. Returns true if a NUL is present anywhere.
// Note: this rejects the *character* U+0000 (raw, or produced by
// the JSON parser from the six-character backslash-u0000 escape).
// Text that still contains a literal backslash followed by "u0000"
// after parsing is an ordinary string and passes.
bool contains_nul(const nlohmann::json& j);

// ── Checked canonicalization (library error path) ─────────────
// Rejection-aware entry point: scans for U+0000 first, then
// canonicalizes into `out`. Returns false (leaving `out` empty)
// if any string contains U+0000, true on success. Bool-return
// sentinel style — the library is built with -fno-exceptions, so
// errors propagate by return value (cf. nlohmann's is_discarded()).
bool canonicalize_json_checked(const nlohmann::json& j, std::string& out);

} // namespace baion::std_lib
