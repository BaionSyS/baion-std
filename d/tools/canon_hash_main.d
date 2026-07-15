// BAION canon-hash CLI for D — canonicalize JSON and hash.
// Public standalone tool.
//
// Reads UTF-8 JSON on stdin, writes the SHA-256 of its canonical form
// (sorted keys, no whitespace, shortest-round-trip floats) as lowercase
// hex + newline. Exit 0 on success, nonzero on parse error, on a
// duplicate object key (decoded names) at any depth, or when stdin is
// not exactly one JSON document (empty input, trailing data,
// concatenated documents, trailing comma).

module tools.canon_hash_main;

import std.array : appender;
import std.json : parseJSON;
import std.stdio : stdin, stdout, stderr;

import baionstd.canonical_json : canonicalizeJSON, hasDuplicateKeys,
    hasUnsupportedNumber, scanSingleDocument;
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
        // WHY validate + parse in one step: parseJSON rejects both malformed
        // JSON and invalid UTF-8, which is exactly the CLI's error contract.
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
