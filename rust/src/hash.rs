// BAION canonical JSON for Rust — SHA-256 hash helper.
// Public standalone library: lowercase-hex SHA-256 over canonical JSON bytes.

use sha2::{Digest, Sha256};

/// SHA-256 of arbitrary bytes as lowercase hex.
/// Backs the baion_canon_hash CLI: the digest is taken over the canonical
/// JSON bytes so every language implementation keys identical content
/// identically.
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let digest = hasher.finalize();
    let mut out = String::with_capacity(64);
    for b in digest {
        out.push_str(&format!("{:02x}", b));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_hex_reference() {
        // Fixed reference string; full digest, lowercase hex.
        let got = sha256_hex("6ba7b810-9dad-11d1-80b4-00c04fd430c8".as_bytes());
        assert_eq!(
            got,
            "e5855ff48799c52c9ccf80b82bab9492c347a316876dbeaafef22b0bd4fac13d"
        );
    }

    #[test]
    fn sha256_hex_deterministic() {
        let a = sha256_hex(b"6ba7b810-9dad-11d1-80b4-00c04fd430c8");
        let b = sha256_hex(b"6ba7b810-9dad-11d1-80b4-00c04fd430c8");
        assert_eq!(a, b);
    }

    #[test]
    fn sha256_hex_empty_input_does_not_panic() {
        // SHA-256 of empty input is the well-known e3b0c442... digest.
        let got = sha256_hex(b"");
        assert_eq!(
            got,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }
}
