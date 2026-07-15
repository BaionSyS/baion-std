// BAION canon-hash CLI for D — canonicalize JSON and hash.
// Public standalone tool.
//
// Reads UTF-8 JSON on stdin, writes the SHA-256 of its canonical form
// (sorted keys, no whitespace, shortest-round-trip floats) as lowercase
// hex + newline. Exit 0 on success, nonzero on parse error.

module tools.canon_hash_main;

import std.array : appender;
import std.json : parseJSON;
import std.stdio : stdin, stdout, stderr;

import baionstd.canonical_json : canonicalizeJSON;
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
