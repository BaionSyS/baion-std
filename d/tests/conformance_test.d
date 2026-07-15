// BAION canonical JSON for D — cross-lineage conformance tests.
// Public standalone library.
//
// The shared fixture lives one level above the lineage dir so all
// lineage libraries test against the identical bytes.

module tests.conformance_test;

import std.file : readText;
import std.json;

import baionstd;

// ── Helper: load shared conformance reference ──

JSONValue loadReference()
{
    return parseJSON(readText("../conformance_reference.json"));
}

// ── Helper: canonicalize a fixture document and check both the canonical
// JSON bytes and the SHA-256 of those bytes against the reference ──
void checkDocument(JSONValue ref_, string key)
{
    string canonical = canonicalizeJSON(ref_[key]);
    string expected = ref_[key ~ "_canonical_json"].str;
    assert(canonical == expected,
            "Canonical JSON mismatch for " ~ key ~ ".\n" ~ "  Expected: "
            ~ expected ~ "\n" ~ "  Got:      " ~ canonical);

    string hex = sha256Hex(canonical);
    string expectedHex = ref_[key ~ "_sha256_hex"].str;
    assert(hex == expectedHex,
            "SHA-256 mismatch for " ~ key ~ ".\n" ~ "  Expected: "
            ~ expectedHex ~ "\n" ~ "  Got:      " ~ hex);
}

// ── Test 1: Canonical JSON + SHA-256 — reference document ──
unittest
{
    checkDocument(loadReference(), "reference_document");
}

// ── Test 2: Canonical JSON + SHA-256 — unicode document ──
unittest
{
    checkDocument(loadReference(), "reference_document_unicode");
}

// ── Test 3: Canonical JSON + SHA-256 — edge-case document ──
unittest
{
    checkDocument(loadReference(), "reference_document_edges");
}

// ── Test 4: plain SHA-256 vector ──
unittest
{
    auto ref_ = loadReference();

    string input = ref_["reference_sha256_input"].str;
    string hex = sha256Hex(input);
    string expectedHex = ref_["reference_sha256_hex"].str;
    assert(hex == expectedHex,
            "Test 4 FAILED: SHA-256 hex mismatch.\n" ~ "  Expected: "
            ~ expectedHex ~ "\n" ~ "  Got:      " ~ hex);
}

// ── Test integer-valued floats: canonicalize without trailing decimal ──
// Build the value with explicit float-tagged numbers in D's native type
// system (JSONType.float_) so the parser never has a chance to demote
// them to integers; RFC 8785 requires 1.0 → "1".
unittest
{
    auto ref_ = loadReference();

    JSONValue[string] obj;
    obj["frac"] = JSONValue(1.5);
    obj["neg"] = JSONValue(-7.0);
    obj["vals"] = JSONValue([JSONValue(1.0), JSONValue(2.0), JSONValue(3.0)]);
    JSONValue v = JSONValue(obj);

    string canonical = canonicalizeJSON(v);
    string expected = ref_["reference_integer_valued_floats_canonical_json"].str;

    assert(canonical == expected, "Test integer-valued floats FAILED: integer-valued-float stripping mismatch.\n"
            ~ "  Expected: " ~ expected ~ "\n" ~ "  Got:      " ~ canonical);
}

// ── Canonical JSON edge cases ──
unittest
{
    // Sorted keys at every nesting level, no whitespace
    auto v = parseJSON(`{"z":1,"a":{"y":2,"b":[true,null,"x/y"]}}`);
    assert(canonicalizeJSON(v) == `{"a":{"b":[true,null,"x/y"],"y":2},"z":1}`,
            "edge case FAILED: sorted keys / minimal escaping");

    // Control-char and quote escaping
    auto s = parseJSON(`{"k":"a\"b\\c\n"}`);
    assert(canonicalizeJSON(s) == `{"k":"a\"b\\c\n"}`,
            "edge case FAILED: string escaping");

    // Non-ASCII UTF-8 passes through unescaped
    auto u = parseJSON(`{"k":"é"}`);
    assert(canonicalizeJSON(u) == "{\"k\":\"é\"}",
            "edge case FAILED: UTF-8 passthrough");

    // NaN/Infinity are not representable in JSON — serialize as null
    JSONValue nan = JSONValue(double.nan);
    assert(canonicalizeJSON(nan) == "null", "edge case FAILED: NaN → null");

    // Exponent normalization (Ryu format: no +, no zero-padding)
    JSONValue tiny = JSONValue(5e-8);
    assert(canonicalizeJSON(tiny) == "5e-8", "edge case FAILED: exponent normalization");
}

// ── U+0000 rejection (contract change, external review) ──
// Any string — object key or string value, any depth — containing U+0000
// must be rejected. A literal backslash followed by "u0000" text is NOT
// a NUL and must pass through unchanged.
unittest
{
    import std.exception : assertThrown, collectExceptionMsg;
    import std.algorithm.searching : canFind;

    // U+0000 in a string value (JSON \u0000 escape decodes to a real NUL)
    auto nulValue = parseJSON(`{"x":"a\u0000b"}`);
    string msg = collectExceptionMsg(canonicalizeJSON(nulValue));
    assert(msg !is null && msg.canFind("U+0000"),
            "U+0000 rejection FAILED: value containing NUL not rejected with U+0000 message");

    // U+0000 in an object key
    auto nulKey = parseJSON(`{"a\u0000":1}`);
    assertThrown(canonicalizeJSON(nulKey),
            "U+0000 rejection FAILED: key containing NUL not rejected");

    // U+0000 nested deep inside arrays/objects
    auto nulDeep = parseJSON(`{"a":[1,{"b":["\u0000"]}]}`);
    assertThrown(canonicalizeJSON(nulDeep),
            "U+0000 rejection FAILED: nested NUL not rejected");

    // Literal backslash + "u0000" text (JSON \\u0000) is NOT a NUL — allowed
    auto literalBackslash = parseJSON(`{"x":"a\\u0000b"}`);
    assert(canonicalizeJSON(literalBackslash) == `{"x":"a\\u0000b"}`,
            "U+0000 rejection FAILED: literal backslash + u0000 text wrongly rejected");
}

// ── Duplicate object-key rejection (contract change) ──
// Objects with duplicate member names (compared on DECODED key text,
// any depth) must be rejected. The scan runs on the RAW input because
// parseJSON's associative array silently keeps the last duplicate.
// WYSIWYG backtick strings below keep escape sequences like \u0061
// as literal JSON text, exactly as the CLI receives them on stdin.
unittest
{
    // Flat duplicate
    assert(hasDuplicateKeys(`{"a":1,"a":2}`),
            "duplicate-key FAILED: flat duplicate not detected");

    // Nested object duplicate
    assert(hasDuplicateKeys(`{"x":{"b":1,"b":2}}`),
            "duplicate-key FAILED: nested duplicate not detected");

    // Escaped duplicate: \u0061 decodes to "a" — keys compare DECODED
    assert(hasDuplicateKeys(`{"a":1,"\u0061":2}`),
            "duplicate-key FAILED: escaped duplicate (decoded comparison) not detected");

    // Object inside an array
    assert(hasDuplicateKeys(`[{"k":1,"k":2}]`),
            "duplicate-key FAILED: object-in-array duplicate not detected");

    // Distinct keys — accepted
    assert(!hasDuplicateKeys(`{"aa":1,"ab":2}`),
            "duplicate-key FAILED: distinct keys wrongly flagged");

    // Sibling objects/arrays each get their own seen-set; the string
    // value "a" and array contents must not be mistaken for keys
    assert(!hasDuplicateKeys(`{"b":1,"a":[1,2]}`),
            "duplicate-key FAILED: array value wrongly flagged");
    assert(!hasDuplicateKeys(`[{"k":1},{"k":2}]`),
            "duplicate-key FAILED: same key in sibling objects wrongly flagged");
    assert(!hasDuplicateKeys(`{"k":"k","v":"k"}`),
            "duplicate-key FAILED: string VALUE matching a key wrongly flagged");
}
