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

// ── Duplicate object-key rejection scan ───────────────────────
// CROSS-LINEAGE CONTRACT: any input containing an object with two
// members whose DECODED key names are equal (at any depth) must be
// rejected before canonicalization. Returns true if a duplicate
// key is present anywhere.
// Note: this operates on the RAW input text via nlohmann's SAX
// interface, because the default DOM parse silently deduplicates
// (keeps last) — post-parse detection is impossible. The SAX key()
// callback receives each key already unescaped, so the six-character
// escape backslash-u0061 and the literal "a" compare equal, matching
// the decoded-name semantics of the contract.
bool has_duplicate_keys(const std::string& raw_input);

// ── Number-domain rejection scan ──────────────────────────────
// CROSS-LINEAGE CONTRACT: any input containing a number outside
// the supported canonical domain must be rejected before
// canonicalization. Returns true if any number (at any depth) is:
//   - written with an exponent (raw token contains 'e' or 'E'),
//     e.g. 1e2 is rejected even though 100 is accepted — the check
//     is lexical, on the source spelling, not the value;
//   - an integer beyond +/-9007199254740992 (2^53, the largest
//     magnitude every lineage's double can hold exactly);
//   - a fraction with magnitude in (0, 1e-6) or >= 1e21, where
//     lineage formatters diverge (scientific-notation thresholds).
// Note: this operates on the RAW input text via nlohmann's SAX
// interface, because number_float() receives the unmodified source
// token alongside the parsed value — the DOM erases the spelling.
bool has_unsupported_number(const std::string& raw_input);

// ── UTF-8 BOM rejection scan ──────────────────────────────────
// CROSS-LINEAGE CONTRACT: a leading UTF-8 byte-order mark
// (EF BB BF) is rejected, not skipped — RFC 8259 §8.1 forbids
// adding a BOM, and silently stripping it would let two byte-
// distinct inputs hash identically. Checks the first three raw
// bytes only; a BOM anywhere else is ordinary string content for
// the parser to judge.
bool has_utf8_bom(const std::string& raw_input);

// ── Checked canonicalization (library error path) ─────────────
// Rejection-aware entry point: scans for U+0000 first, then
// canonicalizes into `out`. Returns false (leaving `out` empty)
// if any string contains U+0000, true on success. Bool-return
// sentinel style — the library is built with -fno-exceptions, so
// errors propagate by return value (cf. nlohmann's is_discarded()).
bool canonicalize_json_checked(const nlohmann::json& j, std::string& out);

} // namespace baion::std_lib
