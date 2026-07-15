// BAION canonical JSON for Rust — public standalone library.
// Canonical form: UTF-8, lexicographically sorted keys, minimal escaping,
// RFC 8785-style number formatting.
//
// Rules:
//   - Keys sorted lexicographically at every nesting level
//   - No whitespace between tokens
//   - Numbers: no leading zeros, no trailing decimal, no unnecessary sign
//   - Strings: minimal escaping (only JSON-required characters)
//
// CROSS-LINEAGE CONTRACT: output must be byte-identical across every
// language implementation of this library — the SHA-256 of the canonical
// bytes is used as a content key, so any divergence breaks key parity.

use serde_json::Value;
use std::collections::BTreeMap;

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
                    out.push_str(&(f as i64).to_string());
                    return;
                }
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
pub fn canonicalize_json(v: &Value) -> String {
    let mut out = String::new();
    canonicalize_value(v, &mut out);
    out
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
        let result = canonicalize_json(&deep);
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
        let result = canonicalize_json(&j);
        // Forward slash NOT escaped (minimal escaping)
        assert!(result.contains("just ascii / and more"));
        assert!(result.contains("\\\"hello\\\""));
    }

    #[test]
    fn number_serialization() {
        let j = json!({"positive": 42, "zero": 0, "negative": -7});
        let result = canonicalize_json(&j);
        assert!(result.contains("\"negative\":-7"));
        assert!(result.contains("\"positive\":42"));
        assert!(result.contains("\"zero\":0"));
    }

    #[test]
    fn integer_valued_floats_drop_trailing_decimal() {
        let j = json!({"vals": [1.0_f64, 2.0_f64], "neg": -7.0_f64, "frac": 1.5_f64});
        let result = canonicalize_json(&j);
        assert_eq!(result, r#"{"frac":1.5,"neg":-7,"vals":[1,2]}"#);
    }

    #[test]
    fn empty_object() {
        let j = json!({});
        assert_eq!(canonicalize_json(&j), "{}");
    }

    #[test]
    fn array_order_preserved() {
        let j = json!([3, 1, 2]);
        assert_eq!(canonicalize_json(&j), "[3,1,2]");
    }
}
