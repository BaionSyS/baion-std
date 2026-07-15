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

/// Write a JSON-quoted string with minimal escaping (RFC 8785 §3.2.2.2).
/// Only escapes characters that JSON requires: " \ and control chars 0x00-0x1F.
/// Forward slash / is NOT escaped.
void writeJSONString(ref Appender!string buf, const(char)[] s)
{
    buf.put('"');
    foreach (i; 0 .. s.length)
    {
        char c = s[i];
        switch (c)
        {
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
