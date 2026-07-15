// BAION canonical JSON for Rust — canon hash CLI.
// Canonical JSON + SHA-256 over the canonical bytes.
//
// Reads UTF-8 JSON on stdin, canonicalizes it (keys sorted at every level,
// no whitespace, minimal escaping, integer-valued floats stripped of ".0"),
// then prints the lowercase-hex SHA-256 of the canonical bytes + newline.
// Exit 0 on success; exit 1 on parse error or on rejected input — any
// object key or string value containing U+0000, or any object with
// duplicate member names at any depth (message to stderr).

use baion_std::canonical_json::canonicalize_json;
use baion_std::dup_check::check_duplicate_keys;
use baion_std::hash::sha256_hex;
use std::io::Read;
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut input = String::new();
    if let Err(e) = std::io::stdin().read_to_string(&mut input) {
        eprintln!("baion_canon_hash: stdin read error: {}", e);
        return ExitCode::from(1);
    }

    // Why serde_json with float_roundtrip: certain doubles otherwise parse
    // off by 1 ULP, changing canonical bytes and therefore the SHA-256.
    let value: serde_json::Value = match serde_json::from_str(&input) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("baion_canon_hash: JSON parse error: {}", e);
            return ExitCode::from(1);
        }
    };

    // CROSS-LINEAGE CONTRACT (external review, 2026-07): duplicate object
    // member names at any depth are rejected. This runs on the RAW input
    // text — the Value above has already collapsed duplicates (serde_json
    // keeps the last), so only a streaming pass can still see them.
    if let Err(e) = check_duplicate_keys(&input) {
        eprintln!("baion_canon_hash: {}", e);
        return ExitCode::from(1);
    }

    // CROSS-LINEAGE CONTRACT (external review, 2026-07): U+0000 anywhere in
    // an object key or string value is rejected — the library walk decides,
    // so the CLI and direct library callers agree on what is refused.
    let canonical = match canonicalize_json(&value) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("baion_canon_hash: {}", e);
            return ExitCode::from(1);
        }
    };
    println!("{}", sha256_hex(canonical.as_bytes()));
    ExitCode::SUCCESS
}
