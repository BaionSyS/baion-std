// BAION canonical JSON for D — public standalone library.
//
// Generic canonical-form serializer: sorted keys, no whitespace,
// shortest-round-trip floats, minimal string escaping (RFC 8785 style).
//
// CAUTION: std.json's JSONValue uses an internal hash map for objects —
// iteration order is NOT sorted. We extract keys, sort them, and
// serialize manually for canonical output.

module baionstd.canonical_json;

import std.json;
import std.algorithm : sort;
import std.array : Appender, appender;
import std.conv : to;
import std.format : format;
import std.math : isNaN, isInfinity;
import std.typecons : Nullable;

import baionstd.types : StdError, errorMessage;

// CROSS-LINEAGE CONTRACT: non-integer floats serialize as the SHORTEST
// decimal string that roundtrips to the same double (RFC 8785 §3.2.2.3 /
// ECMA-262 §7.1.12.1), reassembled WITHOUT exponent notation. The
// number-domain gate guarantees the value is 0 or |v| in [1e-6, 1e21),
// which is exactly the range where ECMA-262 ToString never takes its
// exponent branch — so plain positional layout is the canonical spelling.
// The previous %g-based formatter emitted exponent forms at |v| <= 1e-5
// (0.00001 → "1e-5") and near the 1e21 top, diverging from the C/Go/OCaml
// reference lineages and breaking SHA-256 digest parity.
//
// Locale note: std.format implements float formatting in Phobos (always
// '.' decimal point) and to!double likewise parses locale-independently,
// so unlike the C lineage's snprintf/strtod path this code does not
// depend on the process locale.
/// Shortest round-trip digits via %e precision search (p = 1..17),
/// then ECMA-262 §7.1.12.1 plain-decimal reassembly.
private string formatShortest(double val)
{
    // Shortest digits: smallest precision whose %e output parses back
    // to the identical double.
    string sci;
    foreach (prec; 1 .. 18)
    {
        sci = format("%.*e", prec - 1, val);
        if (to!double(sci) == val)
            break;
    }

    // Pull apart [-]d[.ddd]e±XX into digit string D (mantissa digits,
    // no dot) and n = exp10 + 1 (count of digits before the decimal
    // point in positional form). The exponent is parsed numerically:
    // %e implementations emit 2+ exponent digits and a mandatory sign,
    // so no fixed width can be assumed.
    size_t i = 0;
    bool neg = false;
    if (sci[i] == '-')
    {
        neg = true;
        i++;
    }
    auto digitsBuf = appender!string;
    digitsBuf.put(sci[i]);
    i++;
    if (i < sci.length && sci[i] == '.')
    {
        i++;
        while (sci[i] != 'e' && sci[i] != 'E')
        {
            digitsBuf.put(sci[i]);
            i++;
        }
    }
    i++; // skip 'e'; to!int consumes the +/- sign and leading zeros
    immutable int n = to!int(sci[i .. $]) + 1;

    string digits = digitsBuf[];
    immutable int dl = cast(int) digits.length;

    string outp;
    if (dl <= n && n <= 21)
    {
        // Integer-valued: all digits then zero-padding, no dot. Covers
        // integer-valued doubles too large for exact-precision layout
        // (e.g. 1.000000000000000005e20 rounds to a 21-digit integer).
        outp = digits;
        foreach (_; 0 .. n - dl)
            outp ~= '0';
    }
    else if (0 < n && n <= dl)
    {
        outp = digits[0 .. n] ~ "." ~ digits[n .. $];
    }
    else if (-5 <= n && n <= 0)
    {
        outp = "0.";
        foreach (_; 0 .. -n)
            outp ~= '0';
        outp ~= digits;
    }
    else
    {
        // Only reachable when a caller bypassed the number-domain gate
        // (programmatic JSONValue with |v| >= 1e21 or nonzero |v| < 1e-6):
        // emit a best-effort spelling rather than fail. NON-CANONICAL.
        return format!"%.17g"(val);
    }
    return neg ? "-" ~ outp : outp;
}

/// Convert any JSONValue to canonical JSON string.
string canonicalizeJSON(JSONValue v)
{
    auto buf = appender!string;
    canonicalizeValue(buf, v);
    return buf[];
}

/// Recursively write a JSON value in canonical form.
void canonicalizeValue(ref Appender!string buf, const JSONValue v)
{
    final switch (v.type)
    {
    case JSONType.null_:
        buf.put("null");
        break;

    case JSONType.false_:
        buf.put("false");
        break;

    case JSONType.true_:
        buf.put("true");
        break;

    case JSONType.integer:
        buf.put(to!string(v.get!long));
        break;

    case JSONType.uinteger:
        buf.put(to!string(v.get!ulong));
        break;

    case JSONType.float_:
        double val = v.get!double;
        if (isNaN(val) || isInfinity(val))
        {
            buf.put("null");
        }
        else if (val == 0)
        {
            // CROSS-LINEAGE CONTRACT: any zero — including IEEE-754 negative
            // zero — serializes as exactly "0" (RFC 8785 §3.2.2.3 via ECMA-262
            // ToString: "If x is +0 or -0, return \"0\""). D's %g preserves
            // the sign bit and would emit "-0", diverging from the other
            // lineages, so zero is short-circuited before formatShortest.
            buf.put("0");
        }
        else
        {
            // CROSS-LINEAGE CONTRACT: integer-valued floats serialize without
            // trailing decimal (RFC 8785 §3.2.2.3 / ECMA-262 §7.1.12.1).
            // formatShortest's precision-1 starting point plus the dl <= n
            // reassembly branch guarantee 1.0 → "1", -3.0 → "-3", 1.5 → "1.5".
            buf.put(formatShortest(val));
        }
        break;

    case JSONType.string:
        writeJSONString(buf, v.str);
        break;

    case JSONType.array:
        buf.put('[');
        bool first = true;
        foreach (ref elem; v.array)
        {
            if (!first)
                buf.put(',');
            canonicalizeValue(buf, elem);
            first = false;
        }
        buf.put(']');
        break;

    case JSONType.object:
        // CRITICAL: std.json uses hash map — iteration order is NOT sorted.
        // Extract keys, sort, serialize in sorted order.
        auto obj = v.objectNoRef;
        string[] keys;
        keys.reserve(obj.length);
        foreach (k; obj.byKey())
            keys ~= k;
        keys.sort();

        buf.put('{');
        bool firstObj = true;
        foreach (k; keys)
        {
            if (!firstObj)
                buf.put(',');
            writeJSONString(buf, k);
            buf.put(':');
            canonicalizeValue(buf, obj[k]);
            firstObj = false;
        }
        buf.put('}');
        break;
    }
}

// ── Duplicate object-key rejection scan ───────────────────────
//
// CROSS-LINEAGE CONTRACT: a JSON object with duplicate member names
// (compared on DECODED key text, any depth) is rejected — all 7
// lineages error so the CLI exits 1 mentioning duplicate keys.
// `{"a":1,"\u0061":2}` IS a duplicate: \u0061 decodes to "a".
//
// WHY a raw-input scan and not a post-parse walk: std.json's
// parseJSON stores objects in an associative array and silently
// keeps the LAST duplicate — by the time a JSONValue exists the
// evidence is gone. This scanner tokenizes the raw text instead,
// decoding string escapes so key comparison matches the parser's
// view, and tracking a per-object seen-key set on a nesting stack.
//
// Precondition: the input has already been accepted by parseJSON,
// so this scan may assume well-formed JSON (matched braces, valid
// escapes) and never needs to re-report syntax errors.

/// Scan raw JSON text for duplicate member names within any single
/// object. Returns true if a duplicate (decoded comparison) exists.
bool hasDuplicateKeys(const(char)[] raw)
{
    static struct Frame
    {
        bool isObject;
        bool[string] seen;
    }

    Frame[] stack;
    // True exactly when the next string token is an object member name
    // (right after '{' or after ',' inside an object).
    bool expectKey = false;

    size_t i = 0;
    while (i < raw.length)
    {
        switch (raw[i])
        {
        case '{':
            stack ~= Frame(true, null);
            expectKey = true;
            i++;
            break;
        case '[':
            stack ~= Frame(false, null);
            expectKey = false;
            i++;
            break;
        case '}':
        case ']':
            if (stack.length)
                stack.length -= 1;
            expectKey = false;
            i++;
            break;
        case ',':
            expectKey = stack.length && stack[$ - 1].isObject;
            i++;
            break;
        case ':':
            expectKey = false;
            i++;
            break;
        case '"':
            // Structural ':' ',' '}' inside string literals never reach the
            // cases above: decodeJSONString consumes the whole literal here.
            string decoded = decodeJSONString(raw, i);
            if (expectKey && stack.length && stack[$ - 1].isObject)
            {
                if (decoded in stack[$ - 1].seen)
                    return true;
                stack[$ - 1].seen[decoded] = true;
                expectKey = false;
            }
            break;
        default:
            // Numbers, literals, whitespace — structurally irrelevant here.
            i++;
            break;
        }
    }
    return false;
}

// ── Number-domain enforcement scan ───────────────────────────
//
// CROSS-LINEAGE CONTRACT: number tokens are restricted to a lexical
// domain all 7 lineages accept identically — the check is on the RAW
// token text, so `100` and `1e2` are distinguished even though they
// parse to the same value. Rejected (CLI exits 1 mentioning an
// unsupported number):
//   1. any token containing exponent notation (`e` / `E`)
//   2. integer tokens (no `.`) with magnitude beyond ±9007199254740992
//      (2^53, the IEEE-754 exact-integer bound) — compared as digit
//      strings, never via double, so 9007199254740993 cannot round
//      down to a false accept
//   3. fraction tokens whose value lands where ES ToString would need
//      exponent form: nonzero |v| < 1e-6 or |v| >= 1e21
//
// WHY a raw-input scan and not a post-parse walk: parseJSON has
// already collapsed `1e2` to 100 and rounded 9007199254740993 by the
// time a JSONValue exists — the lexical evidence is gone.
//
// Precondition: as with hasDuplicateKeys, the input has already been
// accepted by parseJSON, so tokens are well-formed JSON numbers.

/// Scan raw JSON text for number tokens outside the supported domain.
/// Returns true if any unsupported number token exists.
bool hasUnsupportedNumber(const(char)[] raw)
{
    size_t i = 0;
    while (i < raw.length)
    {
        char c = raw[i];
        if (c == '"')
        {
            // Digits/'e' inside string literals are not number tokens:
            // consume the whole literal (decoded text is discarded).
            decodeJSONString(raw, i);
            continue;
        }
        if (c == '-' || (c >= '0' && c <= '9'))
        {
            size_t start = i;
            // parseJSON already validated the grammar, so a greedy sweep
            // over number-alphabet chars captures exactly one token.
            while (i < raw.length && (raw[i] == '-' || raw[i] == '+'
                    || raw[i] == '.' || raw[i] == 'e' || raw[i] == 'E'
                    || (raw[i] >= '0' && raw[i] <= '9')))
                i++;
            if (numberTokenUnsupported(raw[start .. i]))
                return true;
            continue;
        }
        i++;
    }
    return false;
}

/// Decide whether one raw number token is outside the supported domain.
private bool numberTokenUnsupported(const(char)[] tok)
{
    import std.conv : to;
    import std.math : fabs;

    bool hasDot = false;
    foreach (c; tok)
    {
        // Exponent notation is rejected outright — even value-preserving
        // forms like 1e2 — because canonical output would erase the
        // distinction and lineages differ in how they re-expand it.
        if (c == 'e' || c == 'E')
            return true;
        if (c == '.')
            hasDot = true;
    }

    if (!hasDot)
    {
        // Integer token: compare DIGIT STRINGS against 2^53. Converting
        // to double first would round 9007199254740993 down to the
        // boundary and wave it through.
        static immutable string maxSafe = "9007199254740992";
        const(char)[] digits = tok;
        if (digits.length && digits[0] == '-')
            digits = digits[1 .. $];
        while (digits.length > 1 && digits[0] == '0')
            digits = digits[1 .. $];
        if (digits.length > maxSafe.length)
            return true;
        if (digits.length == maxSafe.length && digits > maxSafe)
            return true;
        return false;
    }

    // Fraction token: magnitude gate on the parsed value. Outside
    // [1e-6, 1e21) ES ToString switches to exponent form, which the
    // supported domain excludes. Zero (any sign) always passes.
    double v = to!double(tok);
    return (v != 0 && fabs(v) < 1e-6) || fabs(v) >= 1e21;
}

// ── Single-document enforcement scan ─────────────────────────
//
// CROSS-LINEAGE CONTRACT: stdin must contain EXACTLY ONE complete JSON
// document, with only leading/trailing whitespace around it. All 7
// lineages reject empty input, trailing garbage (`{"a":1} x`),
// concatenated documents (`{"a":1}{"b":2}`) and trailing commas
// (`{"a":1,}`) — the CLI exits 1 naming the problem.
//
// WHY a raw-input scan: std.json's parseJSON stops at the end of the
// first complete value and silently IGNORES everything after it, and
// (measured, dmd 2.112.0) also swallows a trailing comma before '}'
// or ']' — so by the time a JSONValue exists none of these defects
// are visible. The consuming-range parseJSON overload does not help
// either: for a char slice it leaves the range untouched rather than
// advancing past the parsed prefix. This scanner walks the raw text
// to the end of the first document and checks the remainder is
// whitespace-only, flagging trailing commas along the way.
//
// Precondition: as with the other raw scanners, parseJSON has already
// accepted the input, so the FIRST document is well-formed; the scan
// never reads past it except to whitespace-check the remainder.

/// Scan raw JSON text for the exactly-one-document contract.
/// Returns the violation, or a null Nullable when the input is one
/// complete document surrounded only by whitespace.
Nullable!StdError scanSingleDocument(const(char)[] raw)
{
    Nullable!StdError err;

    size_t i = 0;
    while (i < raw.length && isJSONWhitespace(raw[i]))
        i++;
    if (i >= raw.length)
    {
        err = StdError.emptyInput;
        return err;
    }

    char c = raw[i];
    if (c == '{' || c == '[')
    {
        // Structural walk to the matching top-level closer. Strings are
        // consumed whole so structural bytes inside literals never count.
        // afterComma tracks whether the last non-whitespace structural
        // token was ',' — true at a closer means a trailing comma, which
        // parseJSON accepts but the contract rejects.
        size_t depth = 0;
        bool afterComma = false;
        while (i < raw.length)
        {
            char t = raw[i];
            if (t == '"')
            {
                decodeJSONString(raw, i);
                afterComma = false;
                continue;
            }
            if (t == '{' || t == '[')
            {
                depth++;
                afterComma = false;
                i++;
                continue;
            }
            if (t == '}' || t == ']')
            {
                if (afterComma)
                {
                    err = StdError.trailingComma;
                    return err;
                }
                depth--;
                i++;
                if (depth == 0)
                    break;
                continue;
            }
            if (t == ',')
                afterComma = true;
            else if (!isJSONWhitespace(t))
                afterComma = false; // ':' and scalar bytes clear the flag
            i++;
        }
    }
    else if (c == '"')
    {
        decodeJSONString(raw, i);
    }
    else if (c == 't')
    {
        i += 4; // "true" — exact literal, parseJSON already validated it
    }
    else if (c == 'f')
    {
        i += 5; // "false"
    }
    else if (c == 'n')
    {
        i += 4; // "null"
    }
    else
    {
        // Number token: greedy sweep over the number alphabet, matching
        // hasUnsupportedNumber. Nonempty for parseJSON-accepted input;
        // exact token extent matters so `123 456` and `123x` leave their
        // second chunk behind as trailing data.
        size_t start = i;
        while (i < raw.length && (raw[i] == '-' || raw[i] == '+'
                || raw[i] == '.' || raw[i] == 'e' || raw[i] == 'E'
                || (raw[i] >= '0' && raw[i] <= '9')))
            i++;
        if (i == start)
            i++; // unreachable for parseJSON-accepted input; keeps the scan advancing
    }

    while (i < raw.length && isJSONWhitespace(raw[i]))
        i++;
    if (i < raw.length)
        err = StdError.trailingData;
    return err;
}

/// RFC 8259 §2 insignificant whitespace: space, tab, LF, CR — nothing else.
private bool isJSONWhitespace(char c) @safe pure nothrow
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

// ── Inter-token control-byte enforcement scan ────────────────
//
// CROSS-LINEAGE CONTRACT: outside string literals only the four RFC
// 8259 §2 whitespace bytes (0x09 TAB, 0x0A LF, 0x0D CR, 0x20 space)
// may separate tokens. All 7 lineages reject any other byte below
// 0x20 between tokens — the CLI exits 1 naming an unsupported
// control character.
//
// WHY a raw-input scan: std.json's parseJSON delegates inter-token
// skipping to isWhite (measured, dmd 2.112.0), which also accepts
// 0x0B vertical tab and 0x0C form feed — so `{"a":1,\x0B"b":2}`
// parses cleanly and the defect is invisible post-parse.
//
// Raw control bytes INSIDE string literals are NOT this scan's job:
// parseJSON already rejects them ("Illegal control character",
// measured dmd 2.112.0) before any raw scan runs, so string literals
// are consumed whole here.
//
// Precondition: as with the other raw scanners, parseJSON has already
// accepted the input, so every string literal is terminated.

/// Scan raw JSON text for control bytes between tokens that are not
/// JSON whitespace. Returns true if any such byte exists.
bool hasUnsupportedControl(const(char)[] raw)
{
    size_t i = 0;
    while (i < raw.length)
    {
        char c = raw[i];
        if (c == '"')
        {
            // Control bytes inside string literals are parseJSON's
            // jurisdiction (see header): consume the whole literal.
            decodeJSONString(raw, i);
            continue;
        }
        if (c < 0x20 && !isJSONWhitespace(c))
            return true;
        i++;
    }
    return false;
}

// ── Raw UTF-8 enforcement scan ───────────────────────────────
//
// CROSS-LINEAGE CONTRACT: the raw input bytes must be well-formed
// RFC 3629 UTF-8. All 7 lineages reject stray continuation bytes,
// truncated sequences, overlong encodings (0xC0/0xC1, 0xE0 0x80-0x9F,
// 0xF0 0x80-0x8F), encoded surrogates (0xED 0xA0-0xBF) and codepoints
// above U+10FFFF (0xF4 0x90+, 0xF5-0xFF) — the CLI exits 1 naming
// invalid UTF-8.
//
// WHY a raw-input scan: std.json's parseJSON (measured, dmd 2.112.0)
// passes non-ASCII bytes through untouched — `{"\xE0a":[]}` and a bare
// `"a\x85b"` parse cleanly and the invalid bytes land in the canonical
// output, diverging from the C++/Rust/Haskell lineages which reject.
//
// UNLIKE the other raw scanners this one has NO parseJSON precondition:
// it runs FIRST, on the raw bytes, before any parse — the other
// scanners (and decodeJSONString) may then assume valid UTF-8.

/// Scan raw input bytes for RFC 3629 well-formedness violations.
/// Returns true if any invalid UTF-8 sequence exists.
bool hasInvalidUTF8(const(ubyte)[] raw) @safe pure nothrow
{
    size_t i = 0;
    while (i < raw.length)
    {
        immutable ubyte b = raw[i];
        if (b < 0x80)
        {
            i++;
            continue;
        }

        // Sequence length and the RFC 3629 §4 tightened range of the
        // SECOND byte — this is where overlong forms, surrogates and
        // > U+10FFFF are excluded, not just the 0x80-0xBF shape.
        size_t len;
        ubyte lo2 = 0x80, hi2 = 0xBF;
        if (b >= 0xC2 && b <= 0xDF)
            len = 2;
        else if (b == 0xE0)
        {
            len = 3;
            lo2 = 0xA0; // 0x80-0x9F would be an overlong 2-byte value
        }
        else if (b >= 0xE1 && b <= 0xEC)
            len = 3;
        else if (b == 0xED)
        {
            len = 3;
            hi2 = 0x9F; // 0xA0-0xBF would encode a UTF-16 surrogate
        }
        else if (b >= 0xEE && b <= 0xEF)
            len = 3;
        else if (b == 0xF0)
        {
            len = 4;
            lo2 = 0x90; // 0x80-0x8F would be an overlong 3-byte value
        }
        else if (b >= 0xF1 && b <= 0xF3)
            len = 4;
        else if (b == 0xF4)
        {
            len = 4;
            hi2 = 0x8F; // 0x90-0xBF would encode above U+10FFFF
        }
        else
        {
            // 0x80-0xBF stray continuation, 0xC0/0xC1 overlong leads,
            // 0xF5-0xFF out-of-range leads.
            return true;
        }

        if (i + len > raw.length)
            return true; // truncated sequence
        if (raw[i + 1] < lo2 || raw[i + 1] > hi2)
            return true;
        foreach (k; 2 .. len)
        {
            if (raw[i + k] < 0x80 || raw[i + k] > 0xBF)
                return true;
        }
        i += len;
    }
    return false;
}

// ── Strict token-lexeme enforcement scan ─────────────────────
//
// CROSS-LINEAGE CONTRACT: number tokens must match the RFC 8259 §6
// grammar exactly (int part is `0` or [1-9] digits — no leading zeros,
// no junk bytes attached to the token), and literal tokens must be
// exactly `null`, `true`, `false` — never case variants. All 7
// lineages reject `0635`, `-004`, `2-`, `77-7957`, `nuLl`, `falSe`,
// `tRue` — the CLI exits 1 naming the invalid token.
//
// WHY a raw-input scan: std.json's parseJSON (measured, dmd 2.112.0)
// accepts leading-zero integers, hashes `2-` / `77-7957` as the
// leading number while silently dropping the tail, and matches the
// null/true/false keywords CASE-INSENSITIVELY — post-parse none of
// this lexical evidence survives. scanSingleDocument cannot catch the
// attached-junk shape either: its greedy number sweep (matching
// parseJSON's own lexer) swallows `-` bytes into the token, so the
// junk never surfaces as trailing data — malformed number lexemes are
// THIS scanner's jurisdiction.
//
// Precondition: hasInvalidUTF8 has already accepted the bytes;
// parseJSON has already accepted the input (lexeme laxities above
// notwithstanding), so string literals are terminated.

/// Scan raw JSON text for number tokens violating the RFC 8259 grammar
/// and for literal tokens that are not exactly null/true/false.
/// Returns the violation, or a null Nullable when every token is clean.
Nullable!StdError scanStrictTokens(const(char)[] raw)
{
    Nullable!StdError err;

    size_t i = 0;
    while (i < raw.length)
    {
        immutable char c = raw[i];
        if (c == '"')
        {
            // Digits/letters inside string literals are not tokens:
            // consume the whole literal (decoded text is discarded).
            decodeJSONString(raw, i);
            continue;
        }
        if (c == '-' || (c >= '0' && c <= '9'))
        {
            // Greedy sweep over the number alphabet — the same lexer view
            // parseJSON takes, so junk it silently attached (`2-`) lands
            // inside the token and fails the grammar check below.
            immutable size_t start = i;
            while (i < raw.length && (raw[i] == '-' || raw[i] == '+'
                    || raw[i] == '.' || raw[i] == 'e' || raw[i] == 'E'
                    || (raw[i] >= '0' && raw[i] <= '9')))
                i++;
            if (!numberTokenGrammarValid(raw[start .. i]))
            {
                err = StdError.invalidNumber;
                return err;
            }
            continue;
        }
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
        {
            // Literal token: sweep the alphabetic run and demand an exact
            // keyword. 'e'/'E' inside numbers never reach here — the
            // number sweep above owns them.
            immutable size_t start = i;
            while (i < raw.length && ((raw[i] >= 'a' && raw[i] <= 'z')
                    || (raw[i] >= 'A' && raw[i] <= 'Z')))
                i++;
            const tok = raw[start .. i];
            if (tok != "null" && tok != "true" && tok != "false")
            {
                err = StdError.invalidLiteral;
                return err;
            }
            continue;
        }
        i++;
    }
    return err;
}

/// Check one raw number token against the RFC 8259 §6 grammar:
/// -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
/// (Exponent forms are grammar-VALID here; hasUnsupportedNumber owns
/// the domain rejection of exponents and out-of-range magnitudes.)
private bool numberTokenGrammarValid(const(char)[] tok) @safe pure nothrow
{
    size_t i = 0;
    if (i < tok.length && tok[i] == '-')
        i++;
    // int part: `0` alone, or a nonzero digit then any digits — a `0`
    // followed by another digit is the leading-zero shape RFC 8259 forbids.
    if (i >= tok.length || tok[i] < '0' || tok[i] > '9')
        return false;
    if (tok[i] == '0')
        i++;
    else
        while (i < tok.length && tok[i] >= '0' && tok[i] <= '9')
            i++;
    if (i < tok.length && tok[i] == '.')
    {
        i++;
        if (i >= tok.length || tok[i] < '0' || tok[i] > '9')
            return false;
        while (i < tok.length && tok[i] >= '0' && tok[i] <= '9')
            i++;
    }
    if (i < tok.length && (tok[i] == 'e' || tok[i] == 'E'))
    {
        i++;
        if (i < tok.length && (tok[i] == '+' || tok[i] == '-'))
            i++;
        if (i >= tok.length || tok[i] < '0' || tok[i] > '9')
            return false;
        while (i < tok.length && tok[i] >= '0' && tok[i] <= '9')
            i++;
    }
    // Any leftover byte is junk parseJSON attached to the token (`2-`).
    return i == tok.length;
}

/// Decode one JSON string literal starting at the opening quote.
/// Advances `i` past the closing quote; returns the decoded text.
/// WHY decode at all: key comparison must match the parser's view,
/// so the keys `"a"` and `"\u0061"` compare equal.
private string decodeJSONString(const(char)[] raw, ref size_t i)
{
    auto buf = appender!string;
    i++; // opening quote
    while (i < raw.length)
    {
        char c = raw[i];
        if (c == '"')
        {
            i++; // closing quote
            break;
        }
        if (c != '\\')
        {
            buf.put(c);
            i++;
            continue;
        }
        i++; // backslash
        if (i >= raw.length)
            break; // unreachable for parseJSON-accepted input
        char e = raw[i];
        i++;
        switch (e)
        {
        case '"':
            buf.put('"');
            break;
        case '\\':
            buf.put('\\');
            break;
        case '/':
            buf.put('/');
            break;
        case 'b':
            buf.put('\b');
            break;
        case 'f':
            buf.put('\f');
            break;
        case 'n':
            buf.put('\n');
            break;
        case 'r':
            buf.put('\r');
            break;
        case 't':
            buf.put('\t');
            break;
        case 'u':
            uint cp = readHex4(raw, i);
            // Surrogate pair: combine high + low into one codepoint,
            // matching how the parser decodes the same escape sequence.
            if (cp >= 0xD800 && cp <= 0xDBFF && i + 5 < raw.length
                    && raw[i] == '\\' && raw[i + 1] == 'u')
            {
                size_t save = i;
                i += 2;
                uint lo = readHex4(raw, i);
                if (lo >= 0xDC00 && lo <= 0xDFFF)
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                else
                    i = save; // lone high surrogate — leave as-is (defensive)
            }
            putCodepoint(buf, cp);
            break;
        default:
            buf.put(e); // unreachable for parseJSON-accepted input
            break;
        }
    }
    return buf[];
}

/// Read exactly 4 hex digits at `i`, advancing past them.
private uint readHex4(const(char)[] raw, ref size_t i)
{
    uint v = 0;
    foreach (_; 0 .. 4)
    {
        if (i >= raw.length)
            return v; // unreachable for parseJSON-accepted input
        char h = raw[i];
        uint d;
        if (h >= '0' && h <= '9')
            d = h - '0';
        else if (h >= 'a' && h <= 'f')
            d = h - 'a' + 10;
        else if (h >= 'A' && h <= 'F')
            d = h - 'A' + 10;
        else
            return v;
        v = (v << 4) | d;
        i++;
    }
    return v;
}

/// UTF-8-encode one codepoint into the buffer.
/// WHY manual and not std.utf.encode: std.utf throws on lone
/// surrogates; the scan only needs a deterministic byte form for
/// EQUALITY comparison, never for output, so encode unconditionally.
private void putCodepoint(ref Appender!string buf, uint cp)
{
    if (cp < 0x80)
    {
        buf.put(cast(char) cp);
    }
    else if (cp < 0x800)
    {
        buf.put(cast(char)(0xC0 | (cp >> 6)));
        buf.put(cast(char)(0x80 | (cp & 0x3F)));
    }
    else if (cp < 0x10000)
    {
        buf.put(cast(char)(0xE0 | (cp >> 12)));
        buf.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        buf.put(cast(char)(0x80 | (cp & 0x3F)));
    }
    else
    {
        buf.put(cast(char)(0xF0 | (cp >> 18)));
        buf.put(cast(char)(0x80 | ((cp >> 12) & 0x3F)));
        buf.put(cast(char)(0x80 | ((cp >> 6) & 0x3F)));
        buf.put(cast(char)(0x80 | (cp & 0x3F)));
    }
}

/// Write a JSON-quoted string with minimal escaping (RFC 8785 §3.2.2.2).
/// Only escapes characters that JSON requires: " \ and control chars 0x01-0x1F.
/// Forward slash / is NOT escaped.
///
/// CROSS-LINEAGE CONTRACT: any string (object key or string value, any depth)
/// containing U+0000 is REJECTED — all 7 lineages throw/error here so the
/// CLI exits 1 with a message mentioning U+0000. A literal backslash followed
/// by "u0000" text is NOT a NUL and passes through unchanged.
void writeJSONString(ref Appender!string buf, const(char)[] s)
{
    buf.put('"');
    foreach (i; 0 .. s.length)
    {
        char c = s[i];
        switch (c)
        {
        case '\0':
            // WHY throw, not escape: contract change (external review) — U+0000
            // anywhere in input strings invalidates the whole document.
            throw new Exception(errorMessage(StdError.nulInString));
        case '"':
            buf.put(`\"`);
            break;
        case '\\':
            buf.put(`\\`);
            break;
        case '\b':
            buf.put(`\b`);
            break;
        case '\f':
            buf.put(`\f`);
            break;
        case '\n':
            buf.put(`\n`);
            break;
        case '\r':
            buf.put(`\r`);
            break;
        case '\t':
            buf.put(`\t`);
            break;
        default:
            if (c < 0x20)
            {
                buf.put(format!`\u%04x`(cast(uint) c));
            }
            else
            {
                buf.put(c);
            }
            break;
        }
    }
    buf.put('"');
}
