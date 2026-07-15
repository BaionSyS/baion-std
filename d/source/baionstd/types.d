// BAION canonical JSON for D — error types. Public standalone library.

module baionstd.types;

/// Library error conditions.
enum StdError
{
    malformedMessage, /// Invalid JSON
    nulInString, /// U+0000 in a string value or object key
    duplicateKey, /// Duplicate member name (decoded) within one object
    unsupportedNumber, /// Number token outside the supported lexical domain
    emptyInput, /// Empty or whitespace-only input (no JSON document at all)
    trailingData, /// Content after the first complete JSON document
    trailingComma, /// Comma immediately before '}' or ']'
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
    case StdError.unsupportedNumber:
        return "unsupported number (exponent notation or out-of-range magnitude) is rejected";
    case StdError.emptyInput:
        return "empty input is rejected (exactly one JSON document is required)";
    case StdError.trailingData:
        return "trailing data after the JSON document is rejected (exactly one JSON document is required)";
    case StdError.trailingComma:
        return "trailing comma before '}' or ']' is rejected";
    }
}
