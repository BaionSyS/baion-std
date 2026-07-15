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

}

// ── ES ToString plain-decimal float spelling (RFC 8785 §3.2.2.3) ──
// The number-domain gate restricts fractions to |v| in [1e-6, 1e21),
// exactly where ECMA-262 ToString never uses exponent form — canonical
// output is therefore ALWAYS plain positional decimal. The previous
// %g-based formatter emitted "1e-5" at |v| <= 1e-5, diverging from the
// C/Go/OCaml reference lineages.
unittest
{
    // Small-fraction band (0 < n <= 0 reassembly): leading "0." + zeros
    assert(canonicalizeJSON(JSONValue(0.001)) == "0.001",
            "plain-decimal FAILED: 0.001");
    assert(canonicalizeJSON(JSONValue(0.0001)) == "0.0001",
            "plain-decimal FAILED: 0.0001");
    assert(canonicalizeJSON(JSONValue(0.000123)) == "0.000123",
            "plain-decimal FAILED: 0.000123");
    assert(canonicalizeJSON(JSONValue(0.00001)) == "0.00001",
            "plain-decimal FAILED: 0.00001 (old formatter emitted 1e-5)");
    assert(canonicalizeJSON(JSONValue(0.000001)) == "0.000001",
            "plain-decimal FAILED: 0.000001 domain floor (old formatter emitted 1e-6)");

    // Mid-range split (0 < n <= dl reassembly)
    assert(canonicalizeJSON(JSONValue(123.456)) == "123.456",
            "plain-decimal FAILED: 123.456");
    assert(canonicalizeJSON(JSONValue(0.25)) == "0.25",
            "plain-decimal FAILED: 0.25");
    assert(canonicalizeJSON(JSONValue(-0.375)) == "-0.375",
            "plain-decimal FAILED: -0.375");

    // Near the 1e21 top (dl <= n <= 21 reassembly): 100000000000000000000.5
    // rounds to an integer-valued double that needs zero-padding to its
    // 21-digit integer spelling, never exponent form.
    assert(canonicalizeJSON(JSONValue(100000000000000000000.5))
            == "100000000000000000000",
            "plain-decimal FAILED: 21-digit integer-valued double near 1e21 top");
    // Integer-valued double above 2^53 (large but exactly representable)
    assert(canonicalizeJSON(JSONValue(1e15)) == "1000000000000000",
            "plain-decimal FAILED: 1e15 integer-valued double");

    // NON-CANONICAL fallback: values outside the domain gate are only
    // reachable via programmatic JSONValue construction; the formatter
    // must still return SOMETHING rather than throw or emit garbage.
    // Spelling is intentionally unpinned beyond being non-empty.
    assert(canonicalizeJSON(JSONValue(5e-8)).length > 0,
            "plain-decimal FAILED: out-of-domain fallback returned empty");
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

// ── Number-domain enforcement (contract change) ──
// The check is LEXICAL on the raw token text: `100` and `1e2` parse to
// the same value but only the latter is rejected. Exponent notation is
// always unsupported; integers are digit-string-compared against 2^53
// (never via double); fractions are magnitude-gated to [1e-6, 1e21).
unittest
{
    // Exponent notation — rejected regardless of value
    assert(hasUnsupportedNumber(`{"x":1e2}`),
            "number-domain FAILED: lowercase exponent not rejected");
    assert(hasUnsupportedNumber(`{"x":1E5}`),
            "number-domain FAILED: uppercase exponent not rejected");
    assert(hasUnsupportedNumber(`{"x":1e-7}`),
            "number-domain FAILED: negative exponent not rejected");
    assert(hasUnsupportedNumber(`[2.5e3]`),
            "number-domain FAILED: exponent inside array not rejected");

    // Same value without exponent notation — accepted
    assert(!hasUnsupportedNumber(`{"x":100}`),
            "number-domain FAILED: plain 100 wrongly rejected");

    // Integer boundary: ±2^53 accepted, one past rejected — digit-string
    // comparison, so the +1 cannot round back down to the boundary
    assert(!hasUnsupportedNumber(`{"x":9007199254740992}`),
            "number-domain FAILED: +2^53 wrongly rejected");
    assert(!hasUnsupportedNumber(`{"x":-9007199254740992}`),
            "number-domain FAILED: -2^53 wrongly rejected");
    assert(hasUnsupportedNumber(`{"x":9007199254740993}`),
            "number-domain FAILED: 2^53+1 not rejected");
    assert(hasUnsupportedNumber(`{"x":-9007199254740993}`),
            "number-domain FAILED: -(2^53+1) not rejected");
    assert(hasUnsupportedNumber(`{"x":10000000000000000000}`),
            "number-domain FAILED: 20-digit integer not rejected");

    // Leading zeros don't inflate the digit count (parseJSON forbids
    // them anyway; defensive against a laxer upstream parser)
    assert(!hasUnsupportedNumber(`{"x":0}`),
            "number-domain FAILED: zero wrongly rejected");

    // Fraction magnitude gate: [1e-6, 1e21) accepted, outside rejected
    assert(!hasUnsupportedNumber(`{"x":0.000001}`),
            "number-domain FAILED: 1e-6 boundary fraction wrongly rejected");
    assert(hasUnsupportedNumber(`{"x":0.0000001}`),
            "number-domain FAILED: sub-1e-6 fraction not rejected");
    assert(hasUnsupportedNumber(`{"x":1000000000000000000000.0}`),
            "number-domain FAILED: 1e21 fraction not rejected");
    assert(!hasUnsupportedNumber(`{"x":0.5}`),
            "number-domain FAILED: 0.5 wrongly rejected");
    assert(!hasUnsupportedNumber(`{"x":-0.0}`),
            "number-domain FAILED: negative zero fraction wrongly rejected");

    // Digits and 'e' inside STRING literals are not number tokens
    assert(!hasUnsupportedNumber(`{"x":"1e2","1E5":"9007199254740993"}`),
            "number-domain FAILED: number-like string content wrongly flagged");
}

// ── Negative zero canonicalizes to "0" (RFC 8785 / ES ToString) ──
// Any zero value — float or integer, signed or not — must emit exactly
// "0". Built with an explicit float-tagged -0.0 so the parser cannot
// demote it to integer zero first.
unittest
{
    JSONValue negZeroFloat = JSONValue(-0.0);
    assert(canonicalizeJSON(negZeroFloat) == "0",
            "negative-zero FAILED: float -0.0 did not emit \"0\"");

    auto negZeroDoc = parseJSON(`{"x":-0.0}`);
    assert(canonicalizeJSON(negZeroDoc) == `{"x":0}`,
            "negative-zero FAILED: parsed {\"x\":-0.0} did not emit {\"x\":0}");

    // std.json parses the integer token -0 to integer zero, which the
    // integer writer already emits as "0" — pinned here so a parser
    // change cannot silently regress it.
    auto negZeroInt = parseJSON(`{"x":-0}`);
    assert(canonicalizeJSON(negZeroInt) == `{"x":0}`,
            "negative-zero FAILED: parsed {\"x\":-0} did not emit {\"x\":0}");

    // Positive zero unchanged
    assert(canonicalizeJSON(JSONValue(0.0)) == "0",
            "negative-zero FAILED: float +0.0 did not emit \"0\"");

    // Nonzero values must NOT be affected by the zero short-circuit
    assert(canonicalizeJSON(JSONValue(0.1)) == "0.1",
            "negative-zero FAILED: 0.1 formatting changed");
    assert(canonicalizeJSON(JSONValue(-1.5)) == "-1.5",
            "negative-zero FAILED: -1.5 formatting changed");
}

// ── Single-document enforcement (contract change) ──
// Input must be exactly one complete JSON document with only whitespace
// around it. The scan runs on the RAW input because parseJSON stops at
// the end of the first complete value and silently ignores trailing
// data, concatenated documents and trailing commas, and parses empty
// input as a null value.
unittest
{
    import baionstd.types : StdError;

    // Exactly one document — accepted (null Nullable)
    assert(scanSingleDocument(`{"a":1}`).isNull,
            "single-document FAILED: plain object wrongly rejected");
    assert(scanSingleDocument(`  {"a":1}  `).isNull,
            "single-document FAILED: surrounding whitespace wrongly rejected");
    assert(scanSingleDocument("{\"a\":1}\n").isNull,
            "single-document FAILED: trailing newline wrongly rejected");
    assert(scanSingleDocument("\t\r\n [1,2] \t").isNull,
            "single-document FAILED: mixed whitespace around array wrongly rejected");

    // Bare scalars are single documents too
    assert(scanSingleDocument(`"hi"`).isNull,
            "single-document FAILED: bare string wrongly rejected");
    assert(scanSingleDocument(`true`).isNull,
            "single-document FAILED: bare true wrongly rejected");
    assert(scanSingleDocument(`false `).isNull,
            "single-document FAILED: bare false wrongly rejected");
    assert(scanSingleDocument(` null`).isNull,
            "single-document FAILED: bare null wrongly rejected");
    assert(scanSingleDocument(`-12.5`).isNull,
            "single-document FAILED: bare number wrongly rejected");

    // Trailing data after the first document
    assert(scanSingleDocument(`{"a":1} x`).get == StdError.trailingData,
            "single-document FAILED: trailing garbage not rejected");
    assert(scanSingleDocument(`{"a":1}{"b":2}`).get == StdError.trailingData,
            "single-document FAILED: concatenated documents not rejected");
    assert(scanSingleDocument(`"hi" "there"`).get == StdError.trailingData,
            "single-document FAILED: two bare strings not rejected");
    assert(scanSingleDocument(`123 456`).get == StdError.trailingData,
            "single-document FAILED: two bare numbers not rejected");
    assert(scanSingleDocument(`true false`).get == StdError.trailingData,
            "single-document FAILED: two bare literals not rejected");
    assert(scanSingleDocument(`{"a":1},`).get == StdError.trailingData,
            "single-document FAILED: comma after top-level document not rejected");

    // Structural bytes inside STRING literals are not document ends
    assert(scanSingleDocument(`{"a":"} x"}`).isNull,
            "single-document FAILED: closer inside string mistaken for document end");

    // Trailing comma — parseJSON swallows it, the contract rejects it
    assert(scanSingleDocument(`{"a":1,}`).get == StdError.trailingComma,
            "single-document FAILED: object trailing comma not rejected");
    assert(scanSingleDocument(`[1,2,]`).get == StdError.trailingComma,
            "single-document FAILED: array trailing comma not rejected");
    assert(scanSingleDocument(`{"a":[1,]}`).get == StdError.trailingComma,
            "single-document FAILED: nested trailing comma not rejected");
    assert(scanSingleDocument("{\"a\":1, \n}").get == StdError.trailingComma,
            "single-document FAILED: whitespace-separated trailing comma not rejected");

    // Empty and whitespace-only input
    assert(scanSingleDocument(``).get == StdError.emptyInput,
            "single-document FAILED: empty input not rejected");
    assert(scanSingleDocument("  \t\n").get == StdError.emptyInput,
            "single-document FAILED: whitespace-only input not rejected");

    // Commas between real members must NOT trip the trailing-comma check
    assert(scanSingleDocument(`{"a":1,"b":[1,2]}`).isNull,
            "single-document FAILED: legitimate commas wrongly flagged");
}
