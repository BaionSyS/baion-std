// BAION canonical JSON for Rust — number-domain rejection pass.
// Validates raw JSON text before canonicalization: any number token outside
// the cross-lineage safe domain (exponent notation, integers beyond the
// double-exact range, fractions outside [1e-6, 1e21)) is rejected.
// Lineage: raw-input byte scanner, modeled on the D lineage's raw scanner
// (d/source/baionstd/canonical_json.d).
//
// CROSS-LINEAGE CONTRACT (external review, 2026-07): the number domain must
// be enforced LEXICALLY. serde_json hands the Visitor only f64/i64/u64
// values, so `1e2` and `100` are indistinguishable after parse — a post-parse
// walk cannot see exponent notation, and huge integer literals have already
// been rounded. Only a scan of the raw text can distinguish them. The scan
// runs after the parse pass succeeds, so it may assume well-formed JSON
// (matched braces, valid strings, valid number grammar).

use std::fmt;

/// Rejection error: some number token in the input fell outside the
/// supported cross-lineage domain. `token` is the offending raw text.
#[derive(Debug, PartialEq, Eq)]
pub struct NumberDomainError {
    pub token: String,
    reason: &'static str,
}

impl fmt::Display for NumberDomainError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "input contains unsupported number token {:?} ({}); rejected",
            self.token, self.reason
        )
    }
}

impl std::error::Error for NumberDomainError {}

// Largest integer n such that every integer in [-n, n] is exactly
// representable as an IEEE-754 double: 2^53. Compared as a DIGIT STRING so
// tokens too large for any native integer type are still judged correctly.
const MAX_SAFE_INTEGER_DIGITS: &str = "9007199254740992";

/// Scan raw JSON text and reject any number token outside the supported
/// domain. Returns Ok(()) when every number token is:
///   - free of exponent notation (`e`/`E`),
///   - if an integer (no `.`): within ±9007199254740992 (2^53, the
///     double-exact range), judged on the digit string,
///   - if a fraction (has `.`): zero, or with 1e-6 <= |v| < 1e21.
///
/// Precondition: `input` is well-formed JSON (callers parse it first, as the
/// CLI does). The scanner skips string literals with escape handling, so
/// digits and `e` inside strings are never mistaken for number tokens.
pub fn check_number_domain(input: &str) -> Result<(), NumberDomainError> {
    let bytes = input.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'"' => i = skip_string(bytes, i),
            b'-' | b'0'..=b'9' => {
                let start = i;
                // In well-formed JSON these bytes only ever appear inside a
                // number token (strings were skipped above), so consuming the
                // full number alphabet here cannot overrun the token.
                while i < bytes.len()
                    && matches!(bytes[i], b'0'..=b'9' | b'.' | b'e' | b'E' | b'+' | b'-')
                {
                    i += 1;
                }
                check_token(&input[start..i])?;
            }
            _ => i += 1,
        }
    }
    Ok(())
}

// Advance past a string literal, returning the index just after the closing
// quote. `\` consumes the next byte, so an escaped quote (`\"`) — or a
// backslash before it (`\\`) — never terminates the scan early. Escape
// payloads (`\uXXXX` hex, etc.) contain no `"` or `\`, so byte-stepping
// through them is safe.
fn skip_string(bytes: &[u8], open_quote: usize) -> usize {
    let mut i = open_quote + 1;
    while i < bytes.len() {
        match bytes[i] {
            b'\\' => i += 2,
            b'"' => return i + 1,
            _ => i += 1,
        }
    }
    bytes.len() // unreachable on well-formed input
}

fn check_token(token: &str) -> Result<(), NumberDomainError> {
    let reject = |reason: &'static str| {
        Err(NumberDomainError {
            token: token.to_string(),
            reason,
        })
    };

    // Exponent notation is rejected outright — canonical form across
    // lineages never emits it in-domain, and accepting it would let `1e2`
    // and `100` alias to the same canonical bytes from different sources.
    if token.bytes().any(|b| b == b'e' || b == b'E') {
        return reject("exponent notation is not supported");
    }

    if !token.contains('.') {
        // Integer token: judge magnitude on the digit string, because a
        // token like 99999999999999999999 exceeds every native integer type
        // and must not be pushed through a lossy parse to be judged.
        let digits = token
            .strip_prefix('-')
            .unwrap_or(token)
            .trim_start_matches('0');
        let over = digits.len() > MAX_SAFE_INTEGER_DIGITS.len()
            || (digits.len() == MAX_SAFE_INTEGER_DIGITS.len()
                && digits > MAX_SAFE_INTEGER_DIGITS);
        if over {
            return reject("integer magnitude exceeds 9007199254740992");
        }
    } else {
        // Fraction token: the domain bounds are value-level (1e-6, 1e21),
        // so an f64 parse is the right instrument here — unlike the integer
        // case, in-domain fractions are exactly the doubles we canonicalize.
        let v: f64 = token.parse().unwrap_or(f64::INFINITY);
        if v != 0.0 && v.abs() < 1e-6 {
            return reject("fraction magnitude below 1e-6");
        }
        if v.abs() >= 1e21 {
            return reject("fraction magnitude at or above 1e21");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exponent_lowercase_rejected() {
        let err = check_number_domain(r#"{"x":1e2}"#).unwrap_err();
        assert_eq!(err.token, "1e2");
    }

    #[test]
    fn exponent_uppercase_rejected() {
        let err = check_number_domain(r#"{"x":1E5}"#).unwrap_err();
        assert_eq!(err.token, "1E5");
    }

    #[test]
    fn exponent_negative_rejected() {
        let err = check_number_domain(r#"{"x":1e-7}"#).unwrap_err();
        assert_eq!(err.token, "1e-7");
    }

    #[test]
    fn exponent_overflowing_rejected() {
        // 1e400 overflows f64 to infinity — the lexical check fires first.
        let err = check_number_domain(r#"{"x":1e400}"#).unwrap_err();
        assert_eq!(err.token, "1e400");
    }

    #[test]
    fn plain_hundred_accepted() {
        // The load-bearing distinction: 100 passes where 1e2 / 1E2 do not.
        assert_eq!(check_number_domain(r#"{"x":100}"#), Ok(()));
        assert!(check_number_domain(r#"{"x":1E2}"#).is_err());
    }

    #[test]
    fn max_safe_integer_accepted_both_signs() {
        assert_eq!(
            check_number_domain(r#"{"a":9007199254740992,"b":-9007199254740992}"#),
            Ok(())
        );
    }

    #[test]
    fn integer_past_max_safe_rejected() {
        let err = check_number_domain(r#"{"x":9007199254740993}"#).unwrap_err();
        assert_eq!(err.token, "9007199254740993");
    }

    #[test]
    fn negative_integer_past_max_safe_rejected() {
        let err = check_number_domain(r#"{"x":-9007199254740993}"#).unwrap_err();
        assert_eq!(err.token, "-9007199254740993");
    }

    #[test]
    fn integer_beyond_native_width_rejected() {
        // 21 digits — exceeds u64/i64; must be judged on the digit string.
        let err = check_number_domain(r#"{"x":999999999999999999999}"#).unwrap_err();
        assert_eq!(err.token, "999999999999999999999");
    }

    #[test]
    fn leading_zeros_do_not_inflate_magnitude() {
        // Digit-string compare must strip leading zeros before length compare.
        assert_eq!(check_number_domain(r#"[0.5]"#), Ok(()));
        assert_eq!(check_number_domain(r#"{"x":0}"#), Ok(()));
    }

    #[test]
    fn tiny_fraction_rejected() {
        let err = check_number_domain(r#"{"x":0.0000001}"#).unwrap_err();
        assert_eq!(err.token, "0.0000001");
    }

    #[test]
    fn boundary_fraction_one_millionth_accepted() {
        // |v| == 1e-6 exactly — inside the domain (strict < in the rule).
        assert_eq!(check_number_domain(r#"{"x":0.000001}"#), Ok(()));
    }

    #[test]
    fn huge_fraction_rejected() {
        let err =
            check_number_domain(r#"{"x":10000000000000000000000.0}"#).unwrap_err();
        assert_eq!(err.token, "10000000000000000000000.0");
    }

    #[test]
    fn zero_fractions_accepted() {
        // 0.0 and -0.0 are exempt from the lower-magnitude bound.
        assert_eq!(check_number_domain(r#"{"a":0.0,"b":-0.0}"#), Ok(()));
    }

    #[test]
    fn ordinary_fractions_accepted() {
        assert_eq!(check_number_domain(r#"{"x":0.1,"y":1.0,"z":-2.5}"#), Ok(()));
    }

    #[test]
    fn numbers_inside_strings_ignored() {
        // "1e400" is string CONTENT — the scanner must skip it.
        assert_eq!(check_number_domain(r#"{"x":"1e400"}"#), Ok(()));
    }

    #[test]
    fn escaped_quote_does_not_leak_string_content() {
        // The \" escape must not end the string early and expose 1e9.
        assert_eq!(check_number_domain(r#"{"x":"a\"1e9\"b"}"#), Ok(()));
    }

    #[test]
    fn backslash_before_close_quote_handled() {
        // "...\\" ends the string at the second quote; the 1e9 after the
        // string (as a key's value) must still be caught.
        let err = check_number_domain(r#"{"x":"c:\\","y":1e9}"#).unwrap_err();
        assert_eq!(err.token, "1e9");
    }

    #[test]
    fn nested_structures_scanned() {
        let err = check_number_domain(r#"{"a":[1,{"b":[2,3,1E2]}]}"#).unwrap_err();
        assert_eq!(err.token, "1E2");
    }

    #[test]
    fn error_display_mentions_unsupported_number() {
        let msg = check_number_domain(r#"{"x":1e2}"#).unwrap_err().to_string();
        assert!(msg.contains("unsupported"));
        assert!(msg.contains("number"));
    }
}
