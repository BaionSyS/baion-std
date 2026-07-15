// BAION canonical JSON for D — error types. Public standalone library.

module baionstd.types;

/// Library error conditions.
enum StdError
{
    malformedMessage, /// Invalid JSON
    nulInString, /// U+0000 in a string value or object key
    duplicateKey, /// Duplicate member name (decoded) within one object
}

/// Human-readable error messages.
string errorMessage(StdError e) @safe pure nothrow
{
    final switch (e)
    {
    case StdError.malformedMessage:
        return "malformed message";
    case StdError.nulInString:
        return "U+0000 in string value or object key is rejected";
    case StdError.duplicateKey:
        return "duplicate object key (decoded name) is rejected";
    }
}
