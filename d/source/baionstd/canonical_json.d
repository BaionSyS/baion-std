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

import baionstd.types : StdError, errorMessage;

// CROSS-LINEAGE CONTRACT: this formatting must produce byte-identical output
// with Rust's Ryu (serde_json) and C++'s nlohmann::json shortest-round-trip.
// All lineages must agree on the decimal representation so that
// canonical JSON and therefore SHA-256 digests match.
//
// WHY: D's %g diverges from Ryu in two ways that must be post-processed:
//   1. Zero-pads exponents:    5e-08  vs Ryu's 5e-8
//   2. Includes + sign:        e+15   vs Ryu omits +
// The %g shortest-search itself matches Ryu for all values in the
// pipeline's float range.
/// Iterates %g precision from 1..17 until parse(format(val)) == val,
/// then normalizes exponent formatting to match Ryu.
private string formatShortest(double val)
{
    foreach (prec; 1 .. 18)
    {
        string s = format("%.*g", prec, val);
        if (to!double(s) == val)
            return normalizeExponent(s);
    }
    // Fallback: full 17-digit precision (unreachable for finite IEEE-754 doubles)
    return normalizeExponent(format!"%.17g"(val));
}

/// Post-process %g output to match Ryu's exponent format.
/// WHY: D's libc %g zero-pads exponents (5e-08 → 5e-8) and includes
/// + sign (e+15 → e15). Ryu never does either.
private string normalizeExponent(string s)
{
    import std.string : indexOf;

    auto eIdx = s.indexOf('e');
    if (eIdx < 0)
        eIdx = s.indexOf('E');
    if (eIdx < 0)
        return s; // No exponent, no fixup needed

    string mantissa = s[0 .. eIdx];
    string expPart = s[eIdx + 1 .. $];

    // Parse exponent: strip + sign and leading zeros
    bool negExp = false;
    size_t ei = 0;
    if (ei < expPart.length && expPart[ei] == '+')
        ei++;
    else if (ei < expPart.length && expPart[ei] == '-')
    {
        negExp = true;
        ei++;
    }
    while (ei < expPart.length - 1 && expPart[ei] == '0')
        ei++;

    return mantissa ~ "e" ~ (negExp ? "-" : "") ~ expPart[ei .. $];
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
        else
        {
            // CROSS-LINEAGE CONTRACT: integer-valued floats serialize without
            // trailing decimal (RFC 8785 §3.2.2.3 / ECMA-262 §7.1.12.1). The
            // %g-based formatShortest below performs the shortest-round-trip
            // search starting at precision 1, so 1.0 → "1", -3.0 → "-3", and
            // 1.5 → "1.5".
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
