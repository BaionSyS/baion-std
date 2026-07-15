// BAION canonical JSON for Rust — cross-implementation conformance tests.
// Verifies byte-identical canonical JSON and identical SHA-256 output against
// the fixture shared by all language implementations of this library.
//
// CROSS-LINEAGE CONTRACT: ../conformance_reference.json (shared fixture at
// the repository root) must remain byte-identical across all language
// directories.

use baion_std::canonical_json::canonicalize_json;
use baion_std::hash::sha256_hex;
use serde_json::{json, Value};
use std::fs;

const FIXTURE_PATH: &str = "../conformance_reference.json";

fn load_ref() -> Value {
    let data =
        fs::read_to_string(FIXTURE_PATH).unwrap_or_else(|e| panic!("read {}: {}", FIXTURE_PATH, e));
    serde_json::from_str(&data).expect("parse conformance_reference.json")
}

/// Canonicalize the fixture input named `key`, compare against the fixture's
/// expected canonical string, then compare the SHA-256 of the canonical bytes
/// against the fixture's expected digest.
fn check_document(r: &Value, key: &str) {
    let input = r
        .get(key)
        .unwrap_or_else(|| panic!("fixture missing key {}", key));
    let got = canonicalize_json(input);

    let canon_key = format!("{}_canonical_json", key);
    let want = r[canon_key.as_str()]
        .as_str()
        .unwrap_or_else(|| panic!("fixture missing key {}", canon_key));
    assert_eq!(got, want, "{} — canonical JSON mismatch", key);

    let hash_key = format!("{}_sha256_hex", key);
    let want_hash = r[hash_key.as_str()]
        .as_str()
        .unwrap_or_else(|| panic!("fixture missing key {}", hash_key));
    assert_eq!(
        sha256_hex(got.as_bytes()),
        want_hash,
        "{} — SHA-256 mismatch",
        key
    );
}

#[test]
fn conformance_reference_document() {
    check_document(&load_ref(), "reference_document");
}

#[test]
fn conformance_reference_document_unicode() {
    check_document(&load_ref(), "reference_document_unicode");
}

#[test]
fn conformance_reference_document_edges() {
    check_document(&load_ref(), "reference_document_edges");
}

// Plain SHA-256 vector: digest of a fixed input string, independent of
// canonicalization, to pin the hash implementation itself.
#[test]
fn conformance_sha256_hex() {
    let r = load_ref();
    let input = r["reference_sha256_input"].as_str().unwrap();
    let got = sha256_hex(input.as_bytes());
    let want = r["reference_sha256_hex"].as_str().unwrap();
    assert_eq!(got, want, "SHA-256 hex mismatch");
}

// Integer-valued floats — canonicalize without trailing decimal
// (fixed 2026-05-04: earlier float formatting diverged from RFC 8785).
// Each implementation builds the value programmatically with explicit
// float-tagged numbers so the parser never has a chance to demote them to
// integers in its native type system.
#[test]
fn conformance_integer_valued_floats() {
    let r = load_ref();
    let v = json!({
        "vals": [1.0_f64, 2.0_f64, 3.0_f64],
        "neg": -7.0_f64,
        "frac": 1.5_f64
    });
    let got = canonicalize_json(&v);
    let want = r["reference_integer_valued_floats_canonical_json"]
        .as_str()
        .expect("reference_integer_valued_floats_canonical_json str");
    assert_eq!(got, want, "integer-valued-float stripping mismatch");
}
