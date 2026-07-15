// BAION canonical hash CLI for C++ — canonicalize-then-hash.
//
// Reads UTF-8 JSON on stdin, canonicalizes it with the BAION
// canonical JSON rules, prints the lowercase-hex SHA-256 of the
// canonical bytes followed by a newline. Exit 0 on success,
// nonzero on parse error, on U+0000 anywhere in a string, or on
// a duplicate object key (decoded names) at any depth.

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
