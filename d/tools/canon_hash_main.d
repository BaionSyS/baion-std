// BAION canon-hash CLI for D — canonicalize JSON and hash.
// Public standalone tool.
//
// Reads UTF-8 JSON on stdin, writes the SHA-256 of its canonical form
// (sorted keys, no whitespace, shortest-round-trip floats) as lowercase
// hex + newline. Exit 0 on success, nonzero on parse error, on a
// duplicate object key (decoded names) at any depth, on a raw control
// byte between tokens that is not JSON whitespace, on invalid UTF-8 in
// the raw bytes (RFC 3629), on a number token violating the RFC 8259
// grammar (leading zero, attached junk), on a literal that is not
// exactly null/true/false, or when stdin is not exactly one JSON
// document (empty input, trailing data, concatenated documents,
// trailing comma).

module tools.canon_hash_main;

import std.array : appender;
import std.json : parseJSON;
import std.stdio : stdin, stdout, stderr;

import baionstd.canonical_json : canonicalizeJSON, hasDuplicateKeys,
    hasInvalidUTF8, hasUnsupportedControl, hasUnsupportedNumber,
    scanSingleDocument, scanStrictTokens;
import baionstd.hash : sha256Hex;
import baionstd.types : StdError, errorMessage;

int main()
{
    auto buf = appender!(ubyte[]);
    foreach (chunk; stdin.byChunk(64 * 1024))
        buf.put(chunk);

    string canonical;
    try
    {
        // UTF-8 scan on the RAW BYTES, before any parse — parseJSON
        // (measured, dmd 2.112.0) passes invalid UTF-8 through untouched,
        // and every later scanner assumes RFC 3629-valid input.
        if (hasInvalidUTF8(buf[]))
        {
            stderr.writeln("baion_canon_hash: ", errorMessage(StdError.invalidUTF8));
            return 1;
        }

        auto j = parseJSON(cast(const(char)[]) buf[]);

        // Single-document scan on the RAW input — parseJSON stops at the
        // end of the first complete value and silently ignores trailing
        // data, concatenated documents and trailing commas, and parses
        // empty input as a null value. Runs FIRST among the raw scans:
        // the other two assume the whole buffer is one well-formed
        // document, which only this scan establishes.
        auto docErr = scanSingleDocument(cast(const(char)[]) buf[]);
        if (!docErr.isNull)
        {
            stderr.writeln("baion_canon_hash: ", errorMessage(docErr.get));
            return 1;
        }

        // Strict token-lexeme scan on the RAW input — parseJSON accepts
        // leading-zero numbers, junk attached to a bare number (`2-`
        // hashes as 2) and CASE-INSENSITIVE null/true/false spellings;
        // none of that survives into the parsed value.
        auto tokErr = scanStrictTokens(cast(const(char)[]) buf[]);
        if (!tokErr.isNull)
        {
            stderr.writeln("baion_canon_hash: ", errorMessage(tokErr.get));
            return 1;
        }

        // Control-byte scan on the RAW input — parseJSON's inter-token
        // whitespace skip (isWhite) also accepts 0x0B/0x0C, which RFC
        // 8259 whitespace excludes; the parsed value carries no trace.
        // (In-string raw controls never reach here: parseJSON already
        // rejected them as "Illegal control character".)
        if (hasUnsupportedControl(cast(const(char)[]) buf[]))
        {
            stderr.writeln("baion_canon_hash: ", errorMessage(StdError.unsupportedControl));
            return 1;
        }

        // Duplicate-key scan on the RAW input — parseJSON's associative
        // array has already deduplicated silently (keeps last), so the
        // check cannot run on the parsed value. Runs after parseJSON so
        // the scanner may assume well-formed JSON.
        if (hasDuplicateKeys(cast(const(char)[]) buf[]))
        {
            stderr.writeln("baion_canon_hash: ", errorMessage(StdError.duplicateKey));
            return 1;
        }

        // Number-domain scan is also on the RAW input — parseJSON has
        // already collapsed 1e2 to 100 and rounded out-of-range integers,
        // so the lexical distinction only exists pre-parse.
        if (hasUnsupportedNumber(cast(const(char)[]) buf[]))
        {
            stderr.writeln("baion_canon_hash: ", errorMessage(StdError.unsupportedNumber));
            return 1;
        }

        canonical = canonicalizeJSON(j);
    }
    catch (Exception e)
    {
        stderr.writeln("baion_canon_hash: ", errorMessage(StdError.malformedMessage),
                ": ", e.msg);
        return 1;
    }

    stdout.writeln(sha256Hex(canonical));
    return 0;
}
