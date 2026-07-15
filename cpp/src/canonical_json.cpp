// BAION canonical JSON for C++ — public standalone library.
//
// This is the byte-identity contract. Every design decision here
// must be replicated exactly in the other language implementations.

#include "baion/canonical_json.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

namespace baion::std_lib
{

// ── Internal: escape a string per JSON spec, minimal escaping ─
// Only escapes characters that JSON *requires* to be escaped:
//   " (0x22), \ (0x5C), and control characters 0x00–0x1F.
// Uses \uXXXX for control chars except the six with short escapes.
static void escape_json_string(const std::string& s, std::string& out)
{
    out.push_back('"');
    for (unsigned char c : s)
    {
        switch (c)
        {
        case '"':
            out += "\\\"";
            break;
        case '\\':
            out += "\\\\";
            break;
        case '\b':
            out += "\\b";
            break;
        case '\f':
            out += "\\f";
            break;
        case '\n':
            out += "\\n";
            break;
        case '\r':
            out += "\\r";
            break;
        case '\t':
            out += "\\t";
            break;
        default:
            if (c < 0x20)
            {
                // Control character — \uXXXX
                char buf[8];
                snprintf(buf, sizeof(buf), "\\u%04x", c);
                out += buf;
            }
            else
            {
                out.push_back(static_cast<char>(c));
            }
            break;
        }
    }
    out.push_back('"');
}

// ── Internal: serialize a number to canonical form ────────────
// No leading zeros, no trailing decimal point, no unnecessary sign.
// Integer values serialize as integers (no .0).
// nlohmann::json already distinguishes int vs float types.
static void serialize_number(const nlohmann::json& j, std::string& out)
{
    if (j.is_number_integer())
    {
        // Signed integer
        out += std::to_string(j.get<int64_t>());
    }
    else if (j.is_number_unsigned())
    {
        // Unsigned integer
        out += std::to_string(j.get<uint64_t>());
    }
    else
    {
        // Floating point — use nlohmann's dump which produces
        // minimal representation. We need to ensure no trailing .0
        // for whole numbers, but nlohmann handles this.
        // However, for cross-lineage consistency we use a fixed approach:
        double val = j.get<double>();
        if (std::isnan(val) || std::isinf(val))
        {
            // JSON doesn't support NaN/Inf — serialize as null
            // (this should never happen in valid input)
            out += "null";
            return;
        }
        // CROSS-LINEAGE CONTRACT: integer-valued floats serialize without
        // trailing decimal (RFC 8785 §3.2.2.3 / ECMA-262 §7.1.12.1). All
        // language implementations emit 1.0 → "1", -3.0 → "-3", 1.5 → "1.5";
        // disagreement on this branch breaks SHA-256 digest parity.
        if (val == std::floor(val) && std::abs(val) < 1e15)
        {
            // Serialize as integer to avoid .0 ambiguity
            out += std::to_string(static_cast<int64_t>(val));
        }
        else
        {
            // Use nlohmann's serializer for consistent representation
            out += j.dump();
        }
    }
}

// ── Recursive canonical serialization ─────────────────────────
std::string canonicalize_json(const nlohmann::json& j)
{
    std::string out;

    switch (j.type())
    {
    case nlohmann::json::value_t::null:
        out = "null";
        break;

    case nlohmann::json::value_t::boolean:
        out = j.get<bool>() ? "true" : "false";
        break;

    case nlohmann::json::value_t::number_integer:
    case nlohmann::json::value_t::number_unsigned:
    case nlohmann::json::value_t::number_float:
        serialize_number(j, out);
        break;

    case nlohmann::json::value_t::string:
        escape_json_string(j.get<std::string>(), out);
        break;

    case nlohmann::json::value_t::array:
    {
        out.push_back('[');
        bool first = true;
        for (const auto& elem : j)
        {
            if (!first)
                out.push_back(',');
            out += canonicalize_json(elem);
            first = false;
        }
        out.push_back(']');
        break;
    }

    case nlohmann::json::value_t::object:
    {
        // §3.4: Keys sorted lexicographically at every nesting level
        std::vector<std::string> keys;
        keys.reserve(j.size());
        for (auto it = j.begin(); it != j.end(); ++it)
        {
            keys.push_back(it.key());
        }
        std::sort(keys.begin(), keys.end());

        out.push_back('{');
        bool first = true;
        for (const auto& key : keys)
        {
            if (!first)
                out.push_back(',');
            escape_json_string(key, out);
            out.push_back(':');
            out += canonicalize_json(j.at(key));
            first = false;
        }
        out.push_back('}');
        break;
    }

    default:
        // binary or discarded — should never appear
        out = "null";
        break;
    }

    return out;
}

} // namespace baion::std_lib
