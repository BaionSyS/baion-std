// BAION canonical JSON for C++ — public standalone library.
//
// This is the byte-identity contract. Every design decision here
// must be replicated exactly in the other language implementations.

#include "baion/canonical_json.hpp"

#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <set>
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
        // Floating point — ES-262 ToString restricted to plain decimal
        // (never nlohmann's dump(), which switches to exponent notation).
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
            // CROSS-LINEAGE CONTRACT: non-integer floats serialize as the
            // SHORTEST decimal string that roundtrips to the same double
            // (RFC 8785 §3.2.2.3 / ECMA-262 §7.1.12.1), reassembled WITHOUT
            // exponent notation. The number-domain gate guarantees the value
            // is 0 or |v| in [1e-6, 1e21), which is exactly the range where
            // ECMA-262 ToString never takes its exponent branch — so plain
            // positional layout is the canonical spelling. nlohmann's dump()
            // here previously printed 1e-05 for 0.00001 and 1e+20 near the
            // domain top, diverging from every RFC 8785 lineage.

            // Shortest digits: std::to_chars with chars_format::scientific
            // and default precision emits the minimal round-trip digit
            // string as d[.ddd]e±dd — locale-independent, unlike the %e
            // loop the C lineage uses for the same contract.
            char sci[64];
            const auto rc = std::to_chars(sci, sci + sizeof(sci) - 1, val,
                                          std::chars_format::scientific);
            *rc.ptr = '\0';

            // Pull apart [-]d[.ddd]e±dd into digit string D and
            // n = exp10 + 1 (count of digits before the decimal point in
            // positional form), per ECMA-262 §7.1.12.1 notation.
            const char* s = sci;
            const bool neg = (*s == '-');
            if (neg)
                ++s;
            std::string digits;
            digits.push_back(*s++);
            if (*s == '.')
            {
                ++s;
                while (*s != 'e' && *s != 'E')
                    digits.push_back(*s++);
            }
            ++s; // skip 'e'; strtol consumes the +/- sign of the exponent
            const int n = static_cast<int>(std::strtol(s, nullptr, 10)) + 1;
            const int dl = static_cast<int>(digits.size());

            if (neg)
                out.push_back('-');
            if (dl <= n && n <= 21)
            {
                // Integer-valued but too large for the int64 branch above
                // (|v| >= 1e15): all digits then zero-padding, no dot.
                out += digits;
                out.append(static_cast<std::size_t>(n - dl), '0');
            }
            else if (0 < n && n <= dl)
            {
                out.append(digits, 0, static_cast<std::size_t>(n));
                out.push_back('.');
                out.append(digits, static_cast<std::size_t>(n),
                           std::string::npos);
            }
            else if (-5 <= n && n <= 0)
            {
                out += "0.";
                out.append(static_cast<std::size_t>(-n), '0');
                out += digits;
            }
            else
            {
                // Only reachable when a caller bypassed the number-domain
                // gate (programmatic tree with |v| >= 1e21 or |v| < 1e-6):
                // emit a best-effort spelling rather than mis-slice the
                // digit string. NON-CANONICAL.
                if (neg)
                    out.pop_back();
                char buf[64];
                snprintf(buf, sizeof(buf), "%.17g", val);
                out += buf;
            }
        }
    }
}

// ── U+0000 rejection scan ──────────────────────────────────────
// CROSS-LINEAGE CONTRACT: all lineages reject inputs whose object
// keys or string values contain U+0000 before canonicalization.
// nlohmann preserves NUL inside std::string, so std::string::find
// on the raw bytes is the reliable detector post-parse.
bool contains_nul(const nlohmann::json& j)
{
    switch (j.type())
    {
    case nlohmann::json::value_t::string:
        return j.get_ref<const nlohmann::json::string_t&>().find('\0') !=
               std::string::npos;

    case nlohmann::json::value_t::array:
        for (const auto& elem : j)
        {
            if (contains_nul(elem))
                return true;
        }
        return false;

    case nlohmann::json::value_t::object:
        for (auto it = j.begin(); it != j.end(); ++it)
        {
            if (it.key().find('\0') != std::string::npos ||
                contains_nul(it.value()))
                return true;
        }
        return false;

    default:
        // null / boolean / number / binary — no strings to scan
        return false;
    }
}

// ── Duplicate object-key rejection scan ───────────────────────
// CROSS-LINEAGE CONTRACT: all lineages reject inputs where any
// object (at any depth) repeats a DECODED member name. nlohmann's
// DOM parse keeps the last duplicate silently, so this scan runs
// on the raw text through the SAX interface instead: key() fires
// once per member with the already-unescaped name, and a per-object
// set of seen keys (stack-managed across nesting) detects repeats.
namespace
{
class duplicate_key_scanner final
    : public nlohmann::json_sax<nlohmann::json>
{
public:
    bool found_duplicate = false;

    bool key(string_t& val) override
    {
        // Comparing decoded names: at this point nlohmann has already
        // resolved \uXXXX escapes, so "a" and "a" collide here.
        if (!seen_.back().insert(val).second)
        {
            found_duplicate = true;
            return false; // abort the parse — one duplicate is enough
        }
        return true;
    }

    bool start_object(std::size_t) override
    {
        seen_.emplace_back();
        return true;
    }

    bool end_object() override
    {
        seen_.pop_back();
        return true;
    }

    // Remaining events carry no key information — accept and continue.
    bool null() override { return true; }
    bool boolean(bool) override { return true; }
    bool number_integer(number_integer_t) override { return true; }
    bool number_unsigned(number_unsigned_t) override { return true; }
    bool number_float(number_float_t, const string_t&) override
    {
        return true;
    }
    bool string(string_t&) override { return true; }
    bool binary(binary_t&) override { return true; }
    bool start_array(std::size_t) override { return true; }
    bool end_array() override { return true; }

    bool parse_error(std::size_t, const std::string&,
                     const nlohmann::detail::exception&) override
    {
        // Malformed input is the DOM parse's error to report, not
        // ours — stop scanning without flagging a duplicate.
        return false;
    }

private:
    std::vector<std::set<std::string>> seen_;
};
} // namespace

bool has_duplicate_keys(const std::string& raw_input)
{
    duplicate_key_scanner scanner;
    // Return value ignored deliberately: sax_parse also returns false
    // on plain syntax errors, and only found_duplicate answers the
    // question this scan asks.
    nlohmann::json::sax_parse(raw_input, &scanner);
    return scanner.found_duplicate;
}

// ── Number-domain rejection scan ───────────────────────────────
// CROSS-LINEAGE CONTRACT: all lineages reject numbers outside the
// canonical domain (exponent spellings, integers beyond ±2^53,
// fractions in (0, 1e-6) or >= 1e21). The exponent check must be
// lexical — 100 and 1e2 are the same value but different tokens —
// so this scan uses the SAX interface: number_float() receives the
// raw source token, which the DOM parse discards.
namespace
{
class number_domain_scanner final
    : public nlohmann::json_sax<nlohmann::json>
{
public:
    bool found_unsupported = false;

    // Largest integer magnitude representable exactly in a double
    // across every lineage: 2^53. int64/uint64 comparison is exact —
    // no float conversion happens on this path.
    static constexpr std::int64_t kMaxSafe = 9007199254740992LL;

    bool number_integer(number_integer_t val) override
    {
        if (val > kMaxSafe || val < -kMaxSafe)
        {
            found_unsupported = true;
            return false; // abort the parse — one bad number is enough
        }
        return true;
    }

    bool number_unsigned(number_unsigned_t val) override
    {
        if (val > static_cast<number_unsigned_t>(kMaxSafe))
        {
            found_unsupported = true;
            return false;
        }
        return true;
    }

    bool number_float(number_float_t val, const string_t& raw) override
    {
        // Lexical exponent check: nlohmann routes any token with an
        // exponent or decimal point to number_float and hands us the
        // unmodified source spelling, so 1e2 is caught here while the
        // integer token 100 never reaches this callback.
        if (raw.find('e') != std::string::npos ||
            raw.find('E') != std::string::npos)
        {
            found_unsupported = true;
            return false;
        }
        // A dotless raw token here is an INTEGER that overflowed the
        // 64-bit integer callbacks (nlohmann falls back to
        // number_float on u64/i64 overflow) — the fraction window
        // below would wrongly admit e.g. 100000000000000000000
        // (1e20 < 1e21). Judge it as the integer callbacks do:
        // digit-string comparison against 2^53, exact at any length.
        if (raw.find('.') == std::string::npos)
        {
            if (integer_token_exceeds_max_safe(raw))
            {
                found_unsupported = true;
                return false;
            }
            return true;
        }
        // Magnitude window where all lineage formatters agree on a
        // plain (non-scientific) decimal rendering.
        if ((val != 0.0 && std::fabs(val) < 1e-6) ||
            std::fabs(val) >= 1e21)
        {
            found_unsupported = true;
            return false;
        }
        return true;
    }

    // Compares the raw digit string against 2^53 without any numeric
    // conversion — tokens on this path already overflowed uint64, so
    // only string arithmetic is exact.
    static bool integer_token_exceeds_max_safe(const string_t& raw)
    {
        static const std::string kMaxSafeDigits = "9007199254740992";
        std::size_t i = 0;
        if (i < raw.size() && raw[i] == '-')
            ++i;
        while (i + 1 < raw.size() && raw[i] == '0')
            ++i;
        const std::string digits = raw.substr(i);
        if (digits.size() != kMaxSafeDigits.size())
            return digits.size() > kMaxSafeDigits.size();
        return digits > kMaxSafeDigits;
    }

    // Remaining events carry no number information — accept and continue.
    bool null() override { return true; }
    bool boolean(bool) override { return true; }
    bool string(string_t&) override { return true; }
    bool binary(binary_t&) override { return true; }
    bool key(string_t&) override { return true; }
    bool start_object(std::size_t) override { return true; }
    bool end_object() override { return true; }
    bool start_array(std::size_t) override { return true; }
    bool end_array() override { return true; }

    bool parse_error(std::size_t, const std::string&,
                     const nlohmann::detail::exception&) override
    {
        // Malformed input is the DOM parse's error to report, not
        // ours — stop scanning without flagging a number.
        return false;
    }
};
} // namespace

bool has_unsupported_number(const std::string& raw_input)
{
    number_domain_scanner scanner;
    // Return value ignored deliberately: sax_parse also returns false
    // on plain syntax errors, and only found_unsupported answers the
    // question this scan asks.
    nlohmann::json::sax_parse(raw_input, &scanner);
    return scanner.found_unsupported;
}

// ── UTF-8 BOM rejection scan ───────────────────────────────────
// CROSS-LINEAGE CONTRACT: nlohmann silently skips a leading BOM,
// so a BOM-prefixed document would otherwise hash identically to
// its BOM-free twin — the check must run on the raw bytes before
// any parse touches them.
bool has_utf8_bom(const std::string& raw_input)
{
    return raw_input.size() >= 3 && raw_input[0] == '\xEF' &&
           raw_input[1] == '\xBB' && raw_input[2] == '\xBF';
}

// ── Checked canonicalization (library error path) ─────────────
// Bool-return sentinel because the library is built with
// -fno-exceptions; callers branch on the return value.
bool canonicalize_json_checked(const nlohmann::json& j, std::string& out)
{
    if (contains_nul(j))
    {
        out.clear();
        return false;
    }
    out = canonicalize_json(j);
    return true;
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
