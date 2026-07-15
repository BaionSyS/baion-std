// BAION canonical JSON for Rust — duplicate-object-key rejection pass.
// Validates raw JSON text before canonicalization: any object with two
// members whose DECODED names are equal (at any depth) is rejected.
// Lineage: serde Visitor driven by serde_json's streaming Deserializer.
//
// CROSS-LINEAGE CONTRACT (external review, 2026-07): duplicate object member
// names at any depth must be uniformly rejected by every language
// implementation before canonical bytes are produced. Comparison is over
// DECODED key names — {"a":1,"a":2} is a duplicate — so this cannot be
// a byte scan of the raw text. Parsing to serde_json::Value silently keeps
// the last duplicate, so the check runs a separate streaming pass:
// MapAccess::next_key::<String>() yields every key in source order, decoded,
// including duplicates the Value representation would swallow.

use serde::de::{DeserializeSeed, Deserializer, Error as DeError, MapAccess, SeqAccess, Visitor};
use std::cell::RefCell;
use std::collections::HashSet;
use std::fmt;

/// Rejection error: some object in the input (at any depth) contained two
/// members with the same decoded name. `key` is the offending name.
#[derive(Debug, PartialEq, Eq)]
pub struct DuplicateKeyError {
    pub key: String,
}

impl fmt::Display for DuplicateKeyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "input contains duplicate object key {:?}; rejected",
            self.key
        )
    }
}

impl std::error::Error for DuplicateKeyError {}

// Recursive walk over the token stream. The visitor produces no value — it
// only inspects structure. Scalars are accepted unconditionally; maps track
// decoded key names in a per-map HashSet; seqs recurse into elements.
// The `found` slot smuggles the offending key out of serde's opaque error
// type so the public API can return a typed DuplicateKeyError.
struct DupCheck<'a> {
    found: &'a RefCell<Option<String>>,
}

impl<'de> Visitor<'de> for DupCheck<'_> {
    type Value = ();

    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("any JSON value")
    }

    fn visit_bool<E: DeError>(self, _: bool) -> Result<(), E> {
        Ok(())
    }
    fn visit_i64<E: DeError>(self, _: i64) -> Result<(), E> {
        Ok(())
    }
    fn visit_u64<E: DeError>(self, _: u64) -> Result<(), E> {
        Ok(())
    }
    fn visit_f64<E: DeError>(self, _: f64) -> Result<(), E> {
        Ok(())
    }
    fn visit_str<E: DeError>(self, _: &str) -> Result<(), E> {
        Ok(())
    }
    fn visit_unit<E: DeError>(self) -> Result<(), E> {
        Ok(())
    }

    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<(), A::Error> {
        while seq
            .next_element_seed(DupCheck { found: self.found })?
            .is_some()
        {}
        Ok(())
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<(), A::Error> {
        let mut seen: HashSet<String> = HashSet::new();
        // next_key::<String> decodes escapes, so a and "a" collide here
        // exactly as the contract requires.
        while let Some(key) = map.next_key::<String>()? {
            if !seen.insert(key.clone()) {
                *self.found.borrow_mut() = Some(key.clone());
                return Err(A::Error::custom(format!(
                    "duplicate object key {:?}",
                    key
                )));
            }
            map.next_value_seed(DupCheck { found: self.found })?;
        }
        Ok(())
    }
}

// Language-bridge note: serde requires a DeserializeSeed to recurse a
// stateful visitor into nested values; other lineages express the same
// walk as a plain recursive function over their streaming parser.
impl<'de> DeserializeSeed<'de> for DupCheck<'_> {
    type Value = ();

    fn deserialize<D: Deserializer<'de>>(self, deserializer: D) -> Result<(), D::Error> {
        deserializer.deserialize_any(self)
    }
}

/// Scan raw JSON text for duplicate object member names at any depth,
/// comparing DECODED key names. Returns Ok(()) when no object repeats a key.
///
/// Precondition: `input` is well-formed JSON (callers parse it first, as the
/// CLI does). On malformed input this still errs, reporting an empty key —
/// the parse pass is the authority on syntax, this pass only on duplicates.
pub fn check_duplicate_keys(input: &str) -> Result<(), DuplicateKeyError> {
    let found: RefCell<Option<String>> = RefCell::new(None);
    let mut de = serde_json::Deserializer::from_str(input);
    match de.deserialize_any(DupCheck { found: &found }) {
        Ok(()) => Ok(()),
        Err(_) => Err(DuplicateKeyError {
            key: found.into_inner().unwrap_or_default(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn top_level_duplicate_rejected() {
        let err = check_duplicate_keys(r#"{"a":1,"a":2}"#).unwrap_err();
        assert_eq!(err.key, "a");
    }

    #[test]
    fn nested_duplicate_rejected() {
        let err = check_duplicate_keys(r#"{"x":{"b":1,"b":2}}"#).unwrap_err();
        assert_eq!(err.key, "b");
    }

    #[test]
    fn escaped_duplicate_rejected() {
        // a decodes to "a" — duplicate detection compares DECODED names.
        let err = check_duplicate_keys("{\"a\":1,\"\\u0061\":2}").unwrap_err();
        assert_eq!(err.key, "a");
    }

    #[test]
    fn object_in_array_duplicate_rejected() {
        let err = check_duplicate_keys(r#"[{"k":1,"k":2}]"#).unwrap_err();
        assert_eq!(err.key, "k");
    }

    #[test]
    fn distinct_keys_accepted() {
        assert_eq!(check_duplicate_keys(r#"{"aa":1,"ab":2}"#), Ok(()));
    }

    #[test]
    fn nested_mixed_accepted() {
        assert_eq!(check_duplicate_keys(r#"{"b":1,"a":[1,2]}"#), Ok(()));
    }

    #[test]
    fn same_key_in_sibling_objects_accepted() {
        // "a" repeats across two DIFFERENT objects — not a duplicate.
        assert_eq!(check_duplicate_keys(r#"[{"a":1},{"a":2}]"#), Ok(()));
    }

    #[test]
    fn scalars_and_deep_nesting_accepted() {
        assert_eq!(
            check_duplicate_keys(r#"{"a":{"b":{"c":[null,true,1.5,"s"]}}}"#),
            Ok(())
        );
    }

    #[test]
    fn error_display_mentions_duplicate_key() {
        let err = check_duplicate_keys(r#"{"a":1,"a":2}"#).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("duplicate"));
        assert!(msg.contains("key"));
    }
}
