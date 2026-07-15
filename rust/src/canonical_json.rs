// BAION canonical JSON for Rust — public standalone library.
// Canonical form: UTF-8, lexicographically sorted keys, minimal escaping,
// RFC 8785-style number formatting.
//
// Rules:
//   - Keys sorted lexicographically at every nesting level
//   - No whitespace between tokens
//   - Numbers: no leading zeros, no trailing decimal, no unnecessary sign
//   - Strings: minimal escaping (only JSON-required characters)
//   - U+0000 in any object key or string value (any depth) → rejected
//
// CROSS-LINEAGE CONTRACT: output must be byte-identical across every
// language implementation of this library — the SHA-256 of the canonical
// bytes is used as a content key, so any divergence breaks key parity.

use serde_json::Value;
use std::collections::BTreeMap;

/// Rejection error: the input contained U+0000 (NUL) in an object key or
/// string value at some depth. Canonicalization refuses such input.
#[derive(Debug, PartialEq, Eq)]
pub struct NulInputError;

impl std::fmt::Display for NulInputError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "input contains U+0000 (NUL) in an object key or string value; rejected"
        )
    }
}

impl std::error::Error for NulInputError {}

// CROSS-LINEAGE CONTRACT (external review, 2026-07): any input whose object
// keys or string values contain U+0000 at any depth must be rejected by every
// language implementation before canonical bytes are produced. serde_json
// preserves NUL inside String, so the check is a recursive walk over the
// parsed value — NOT a byte scan of the raw input text. A literal
// backslash-backslash "u0000" sequence in the source decodes to
// backslash + "u0000" text, contains no NUL, and must be accepted.
fn contains_nul(v: &Value) -> bool {
    match v {
        Value::String(s) => s.contains('\u{0000}'),
        Value::Array(arr) => arr.iter().any(contains_nul),
        Value::Object(map) => map
            .iter()
            .any(|(k, v)| k.contains('\u{0000}') || contains_nul(v)),
        _ => false,
    }
}

/// Recursively serialize any serde_json::Value to canonical form.
pub fn canonicalize_value(v: &Value, out: &mut String) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => {
            // CROSS-LINEAGE CONTRACT: integer-valued floats serialize without
            // trailing decimal. RFC 8785 §3.2.2.3 / ECMA-262 §7.1.12.1 ToString
            // for a finite Number whose mathematical value is an integer emits
            // it without ".0". serde_json's Number::to_string preserves ".0"
            // for f64-tagged integer values (e.g. parsing "1.0" round-trips
            // to "1.0", not "1"), which diverges from the other language
            // implementations. Cast integer-valued finite f64 within ±2^53
            // (exact-integer range) to i64 to match.
            // fixed 2026-05-04: earlier float formatting diverged from
            // RFC 8785 — canonicalize_value of json!(1.0) emitted "1.0"
            // instead of "1"; corrected by the integer cast below.
            if n.is_f64() {
                let f = n.as_f64().expect("is_f64 implies as_f64 is Some");
                if f.is_finite() && f == f.trunc() && f.abs() <= 9007199254740992.0 {
                    // Casting also folds -0.0 to 0 ("-0" would diverge from
                    // the ES ToString reference, which emits "0").
                    out.push_str(&(f as i64).to_string());
                    return;
                }
                // CROSS-LINEAGE CONTRACT: floats must serialize as PLAIN
                // DECIMAL (ES ToString form), never exponent notation.
                // serde_json's Number::to_string (Ryu writer) flips to
                // exponent form below 1e-5 ("1e-6") and near the top of the
                // domain ("1e20") — diverging from the C/Go/OCaml reference.
                // Rust std Display for f64 is shortest-roundtrip and never
                // uses exponent notation, which matches ES ToString exactly
                // across the whole supported domain [1e-6, 1e21); the raw
                // lexical gate (num_check) has already rejected anything
                // outside it. Integer-valued floats past 2^53 (e.g. 1e20)
                // land here too — Display gives the full digit string.
                out.push_str(&format!("{}", f));
                return;
            }
            out.push_str(&n.to_string());
        }
        Value::String(s) => escape_json_string(s, out),
        Value::Array(arr) => {
            out.push('[');
            for (i, elem) in arr.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonicalize_value(elem, out);
            }
            out.push(']');
        }
        Value::Object(map) => {
            // Keys sorted lexicographically at every nesting level.
            // serde_json::Map preserves insertion order but is NOT sorted.
            // We must sort explicitly.
            let mut sorted: BTreeMap<&str, &Value> = BTreeMap::new();
            for (k, v) in map.iter() {
                sorted.insert(k.as_str(), v);
            }

            out.push('{');
            let mut first = true;
            for (k, v) in sorted.iter() {
                if !first {
                    out.push(',');
                }
                escape_json_string(k, out);
                out.push(':');
                canonicalize_value(v, out);
                first = false;
            }
            out.push('}');
        }
    }
}

/// Escape a string per JSON spec, minimal escaping only.
/// Only escapes characters that JSON *requires*:
///   " (0x22), \ (0x5C), and control characters 0x00–0x1F.
fn escape_json_string(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{0008}' => out.push_str("\\b"),
            '\u{000C}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                // Control character — \uXXXX
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

/// Canonicalize any JSON value to a string. Convenience wrapper.
/// Rejects any value containing U+0000 in an object key or string value
/// (CROSS-LINEAGE CONTRACT — see contains_nul above).
pub fn canonicalize_json(v: &Value) -> Result<String, NulInputError> {
    if contains_nul(v) {
        return Err(NulInputError);
    }
    let mut out = String::new();
    canonicalize_value(v, &mut out);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn deep_nested_key_sorting() {
        let deep = json!({
            "z": {"m": 1, "a": 2},
            "a": {"z": {"b": true, "a": false}, "a": "first"}
        });
        let result = canonicalize_json(&deep).unwrap();
        let expected = r#"{"a":{"a":"first","z":{"a":false,"b":true}},"z":{"a":2,"m":1}}"#;
        assert_eq!(result, expected);
    }

    #[test]
    fn minimal_string_escaping() {
        let j = json!({
            "quote": "he said \"hello\"",
            "backslash": "path\\to\\file",
            "newline": "line1\nline2",
            "tab": "col1\tcol2",
            "normal": "just ascii / and more"
        });
        let result = canonicalize_json(&j).unwrap();
        // Forward slash NOT escaped (minimal escaping)
        assert!(result.contains("just ascii / and more"));
        assert!(result.contains("\\\"hello\\\""));
    }

    #[test]
    fn number_serialization() {
        let j = json!({"positive": 42, "zero": 0, "negative": -7});
        let result = canonicalize_json(&j).unwrap();
        assert!(result.contains("\"negative\":-7"));
        assert!(result.contains("\"positive\":42"));
        assert!(result.contains("\"zero\":0"));
    }

    #[test]
    fn integer_valued_floats_drop_trailing_decimal() {
        let j = json!({"vals": [1.0_f64, 2.0_f64], "neg": -7.0_f64, "frac": 1.5_f64});
        let result = canonicalize_json(&j).unwrap();
        assert_eq!(result, r#"{"frac":1.5,"neg":-7,"vals":[1,2]}"#);
    }

    #[test]
    fn small_fractions_stay_plain_decimal() {
        // Ryu's default writer flips to exponent form below 1e-5; the
        // contract is ES ToString plain decimal down to the 1e-6 floor.
        let j = json!({"a": 0.001_f64, "b": 0.0001_f64, "c": 0.00001_f64, "d": 0.000001_f64});
        let result = canonicalize_json(&j).unwrap();
        assert_eq!(
            result,
            r#"{"a":0.001,"b":0.0001,"c":0.00001,"d":0.000001}"#
        );
    }

    #[test]
    fn small_fraction_with_significand_plain_decimal() {
        let j = json!({"x": 0.000123_f64});
        assert_eq!(canonicalize_json(&j).unwrap(), r#"{"x":0.000123}"#);
    }

    #[test]
    fn large_float_prints_full_digit_string() {
        // 100000000000000000000.5 rounds to the double 1e20 — an
        // integer-valued float past 2^53, so it skips the i64 cast and
        // must still print as the 21-digit integer form, not "1e20".
        let j: Value = serde_json::from_str(r#"{"x":100000000000000000000.5}"#).unwrap();
        assert_eq!(
            canonicalize_json(&j).unwrap(),
            r#"{"x":100000000000000000000}"#
        );
    }

    #[test]
    fn negative_zero_canonicalizes_to_zero() {
        // ES ToString gives "0" for -0; "-0" would break byte parity.
        let j: Value = serde_json::from_str(r#"{"x":-0.0}"#).unwrap();
        assert_eq!(canonicalize_json(&j).unwrap(), r#"{"x":0}"#);
    }

    #[test]
    fn ordinary_fractions_unchanged_by_plain_decimal_path() {
        let j = json!({"a": 0.1_f64, "b": 123.456_f64, "c": 0.25_f64, "d": -0.375_f64});
        let result = canonicalize_json(&j).unwrap();
        assert_eq!(result, r#"{"a":0.1,"b":123.456,"c":0.25,"d":-0.375}"#);
    }

    #[test]
    fn empty_object() {
        let j = json!({});
        assert_eq!(canonicalize_json(&j).unwrap(), "{}");
    }

    #[test]
    fn nul_in_string_value_rejected() {
        // Parsed \u0000 escape yields a real NUL in the String — must reject.
        let j: Value = serde_json::from_str(r#"{"x":"a\u0000b"}"#).unwrap();
        assert_eq!(canonicalize_json(&j), Err(NulInputError));
    }

    #[test]
    fn nul_in_object_key_rejected() {
        let j: Value = serde_json::from_str(r#"{"a\u0000":1}"#).unwrap();
        assert_eq!(canonicalize_json(&j), Err(NulInputError));
    }

    #[test]
    fn nul_rejected_at_depth() {
        // The contract says "any depth" — check inside a nested array/object.
        let j: Value = serde_json::from_str(r#"{"a":[{"b":"\u0000"}]}"#).unwrap();
        assert_eq!(canonicalize_json(&j), Err(NulInputError));
    }

    #[test]
    fn escaped_backslash_u0000_text_allowed() {
        // JSON source holds \\u0000 (escaped backslash + text) — the parsed
        // string is backslash-u-0-0-0-0 as literal text, no NUL, so it must
        // canonicalize normally.
        let j: Value = serde_json::from_str(r#"{"x":"a\\u0000b"}"#).unwrap();
        assert_eq!(canonicalize_json(&j).unwrap(), r#"{"x":"a\\u0000b"}"#);
    }

    #[test]
    fn array_order_preserved() {
        let j = json!([3, 1, 2]);
        assert_eq!(canonicalize_json(&j).unwrap(), "[3,1,2]");
    }
}
