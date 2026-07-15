// BAION canonical JSON for Rust — canon hash CLI.
// Canonical JSON + SHA-256 over the canonical bytes.
//
// Reads UTF-8 JSON on stdin, canonicalizes it (keys sorted at every level,
// no whitespace, minimal escaping, integer-valued floats stripped of ".0"),
// then prints the lowercase-hex SHA-256 of the canonical bytes + newline.
// Exit 0 on success; nonzero on parse error (message to stderr).

use baion_std::canonical_json::canonicalize_json;
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

    let canonical = canonicalize_json(&value);
    println!("{}", sha256_hex(canonical.as_bytes()));
    ExitCode::SUCCESS
}
