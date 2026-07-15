// BAION canonical hash CLI for C++ — canonicalize-then-hash.
//
// Reads UTF-8 JSON on stdin, canonicalizes it with the BAION
// canonical JSON rules, prints the lowercase-hex SHA-256 of the
// canonical bytes followed by a newline. Exit 0 on success,
// nonzero on parse error, on a leading UTF-8 BOM, on U+0000
// anywhere in a string, on a duplicate object key (decoded names)
// at any depth, or on a number outside the canonical domain
// (exponent spelling, integer beyond +/-2^53, out-of-range
// fraction).

#include "baion/canonical_json.hpp"
#include "baion/hash.hpp"

#include <cstdio>
#include <iostream>
#include <iterator>
#include <string>

int main()
{
    // Slurp all of stdin — canonicalization needs the full document.
    std::string input((std::istreambuf_iterator<char>(std::cin)),
                      std::istreambuf_iterator<char>());

    // BOM scan on the RAW bytes before any parse — nlohmann would
    // silently skip a leading UTF-8 BOM, letting a BOM-prefixed
    // document hash identically to its BOM-free twin.
    if (baion::std_lib::has_utf8_bom(input))
    {
        std::fprintf(stderr,
                     "baion_canon_hash: input starts with a UTF-8 BOM — "
                     "unsupported, rejected\n");
        return 1;
    }

    // Non-throwing parse (library is built with -fno-exceptions).
    nlohmann::json j = nlohmann::json::parse(input, nullptr, false);
    if (j.is_discarded())
    {
        std::fprintf(stderr, "baion_canon_hash: JSON parse error\n");
        return 1;
    }

    // Duplicate-key scan on the RAW input — the DOM parse above has
    // already deduplicated silently (keeps last), so this must run on
    // the original bytes (cross-lineage contract, decoded key names).
    if (baion::std_lib::has_duplicate_keys(input))
    {
        std::fprintf(stderr,
                     "baion_canon_hash: input contains a duplicate object "
                     "key — rejected\n");
        return 1;
    }

    // Number-domain scan on the RAW input — the exponent check is
    // lexical (1e2 rejected, 100 accepted), so it needs the source
    // tokens the DOM parse discards (cross-lineage contract).
    if (baion::std_lib::has_unsupported_number(input))
    {
        std::fprintf(stderr,
                     "baion_canon_hash: input contains an unsupported "
                     "number (exponent notation, integer beyond +/-2^53, "
                     "or out-of-range fraction) — rejected\n");
        return 1;
    }

    // Checked canonicalization — rejects any object key or string
    // value containing U+0000 (cross-lineage contract).
    std::string canonical;
    if (!baion::std_lib::canonicalize_json_checked(j, canonical))
    {
        std::fprintf(stderr,
                     "baion_canon_hash: input contains U+0000 in a string "
                     "or object key — rejected\n");
        return 1;
    }
    const std::string hex = baion::std_lib::sha256_hex(canonical);

    std::fputs(hex.c_str(), stdout);
    std::fputc('\n', stdout);
    return 0;
}
