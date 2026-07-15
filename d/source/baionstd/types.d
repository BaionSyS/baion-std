// BAION canonical JSON for D — error types. Public standalone library.

module baionstd.types;

/// Library error conditions.
enum StdError
{
    malformedMessage, /// Invalid JSON
}

/// Human-readable error messages.
string errorMessage(StdError e) @safe pure nothrow
{
    final switch (e)
    {
    case StdError.malformedMessage:
        return "malformed message";
    }
}
