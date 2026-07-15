// BAION canonical JSON for D — SHA-256 hex helper. Public standalone library.

module baionstd.hash;

import std.digest.sha : SHA256;

// CROSS-LINEAGE CONTRACT: identical UTF-8 input must produce identical
// hex output across all lineage libraries. SHA-256 is FIPS 180-4 (D uses
// std.digest.sha; vendored or native crates in other lineages).
/// Return SHA-256 hex string of the input.
string sha256Hex(string input) pure nothrow @safe
{
    auto sha = SHA256();
    sha.put(cast(const(ubyte)[]) input);
    ubyte[32] digest = sha.finish();

    char[64] hex;
    foreach (i; 0 .. 32)
    {
        hex[i * 2] = hexChar(digest[i] >> 4);
        hex[i * 2 + 1] = hexChar(digest[i] & 0x0F);
    }
    return hex[].idup;
}

private char hexChar(ubyte nibble) pure nothrow @safe
{
    return cast(char)(nibble < 10 ? '0' + nibble : 'a' + nibble - 10);
}
