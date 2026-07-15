// BAION canonical JSON for Rust — public standalone library.
// Canonical form: UTF-8, lexicographically sorted keys, minimal escaping,
// RFC 8785-style number formatting. Pairs with a SHA-256 helper so identical
// content always hashes identically across language implementations.

pub mod canonical_json;
pub mod hash;
