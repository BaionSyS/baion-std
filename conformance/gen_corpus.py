#!/usr/bin/env python3
# BAION STD conformance corpus generator — Make (regenerate accept.jsonl/reject.jsonl)
# Spec: repo README "Supported JSON domain"; corpus-as-data refactor (harden-v0.2.0).
#
# WHY this exists: vectors used to live inline in verify_all_lineages.sh and in seven
# per-lineage test files; every new danger zone meant editing eight places. The corpus
# is now the single source of truth — this script pins each accept case's SHA-256 by
# running ALL SEVEN current CLIs and refusing to pin anything they disagree on, so a
# stale or divergent binary can never mint a wrong expected hash.
#
# Inputs are stored as JSON-escaped strings; consumers must decode the JSON string and
# feed the resulting bytes (UTF-8) to the CLI. Escape-sensitive vectors (the NUL escape, the u0061-spelled key, ud800, the BOM) survive this encoding losslessly, which raw shell arrays did not.
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
LINEAGES = ["c", "cpp", "rust", "go", "d", "haskell", "ocaml"]

BS = chr(0x5C)  # backslash, kept out of literals so editors can't decode escapes
NUL_ESC = BS + "u0000"
A_ESC = BS + "u0061"
LONE_SURROGATE = BS + "ud800"
BOM = chr(0xFEFF)

# name, input-text. Accept cases get hashes pinned at generation time.
ACCEPT = [
    ("key_sort_basic", '{"b":1,"a":[1,2]}'),
    ("key_sort_unicode", '{"z":1,"a":"é"}'),
    ("nested_mixed", '{"nested":{"y":[true,false,null],"x":0.5},"empty":{},"arr":[]}'),
    ("unicode_keys", '{"é":1,"e":2,"zß":"straße"}'),
    ("escape_zoo", '{"escapes":"line' + BS + 'nbreak' + BS + 'ttab ' + BS + '"quoted' + BS + '" back' + BS + BS + 'slash"}'),
    ("max_safe_int", '{"max_safe":9007199254740992,"neg":-42,"empty":""}'),
    ("deep_structure", '{"deep":{"a":{"b":{"c":[1,{"d":[]}]}}}}'),
    ("float_int_normalizes", '{"x":1.0}'),
    ("bare_float_int", "1.0"),
    ("literal_backslash_u0000", '{"x":"a' + BS + BS + 'u0000b"}'),
    ("near_duplicate_keys", '{"aa":1,"ab":2}'),
    ("neg_zero_int", '{"x":-0}'),
    ("neg_zero_float", '{"x":-0.0}'),
    ("plain_decimal", '{"x":0.1}'),
    ("half", '{"x":0.5}'),
    ("surrogate_pair_emoji", '{"x":"\U0001F600"}'),
    ("escaped_solidus", '{"x":"' + BS + '/"}'),
    ("noncharacter_ok", '{"x":"￿"}'),
    ("bare_string", '"hi"'),
    ("bare_true", "true"),
    ("deep_nest_60", ('{"a":' * 60) + "1" + ("}" * 60)),
    ("same_key_sibling_objects", '[{"k":1},{"k":2}]'),
    ("micro_boundary", '{"x":0.000001}'),
    # Pins ES-262 shortest-digits for an integer-valued double beyond 2^53:
    # exact value is ...776 but the canonical spelling is the 16-digit ...780.
    ("big_float_shortest_digits", '{"x":65219416364867774.9377591}'),
]

# Uniform-rejection contract. reason is documentation for humans + remediation maps.
REJECT = [
    ("nul_in_value", '{"x":"a' + NUL_ESC + 'b"}', "U+0000 not representable losslessly in all lineages"),
    ("nul_in_key", '{"a' + NUL_ESC + '":1}', "U+0000 not representable losslessly in all lineages"),
    ("dup_key_toplevel", '{"a":1,"a":2}', "RFC 8259 duplicate-name behavior undefined; three-way divergence observed"),
    ("dup_key_nested", '{"x":{"b":1,"b":2}}', "duplicate detection required at any depth"),
    ("dup_key_escaped", '{"a":1,"' + A_ESC + '":2}', "duplicates compare on the DECODED name"),
    ("dup_key_in_array", '[{"k":1,"k":2}]', "duplicate detection inside objects nested in arrays"),
    ("exponent_lower", '{"x":1e21}', "exponent tokens outside plain-decimal domain"),
    ("exponent_upper", '{"x":1E5}', "exponent tokens outside plain-decimal domain (case-insensitive)"),
    ("exponent_tiny", '{"x":1e-7}', "five-way float-format divergence observed"),
    ("exponent_overflow", '{"x":1e400}', "overflows double; three accept/four reject divergence observed"),
    ("int_beyond_2_53", '{"x":9007199254740993}', "beyond IEEE-754 exact-integer range"),
    ("neg_int_beyond_2_53", '{"x":-9007199254740993}', "beyond IEEE-754 exact-integer range"),
    ("decimal_below_1e_minus_6", '{"x":0.0000001}', "RFC 8785 emits exponent form below 1e-6; outside plain-decimal domain"),
    ("lone_high_surrogate", '{"x":"' + LONE_SURROGATE + '"}', "unpaired surrogate is not a Unicode scalar value"),
    ("leading_bom", BOM + '{"a":1}', "BOM is not JSON; two lineages silently skipped it"),
    ("trailing_garbage", '{"a":1} x', "input must be exactly one JSON document"),
    ("two_documents", '{"a":1}{"b":2}', "input must be exactly one JSON document"),
    ("trailing_comma", '{"a":1,}', "not valid RFC 8259 JSON"),
    ("empty_input", "", "input must be exactly one JSON document"),
    ("raw_tab_in_string", '{"s":"a' + chr(0x09) + 'b"}',
     "RFC 8259 requires control characters in strings to be escaped; three lineages accepted raw TAB"),
    ("raw_ctrl_1e_in_string", '"tr' + chr(0x1E) + 'R"',
     "raw control byte inside string literal; escape it"),
    ("raw_lf_in_string", '{"s":"a' + chr(0x0A) + 'b"}',
     "raw newline inside string literal; spell it as an escape"),
    ("ctrl_between_tokens", '{"a":1,' + chr(0x02) + '"b":2}',
     "only TAB/LF/CR/space are JSON whitespace; one lineage skipped any byte <= 0x20"),
    ("leading_zero_int", "0635", "RFC 8259 int part is 0 or [1-9]digits; two lineages accepted"),
    ("neg_leading_zero_int", "-004", "RFC 8259 int part is 0 or [1-9]digits"),
    ("trailing_dot_number", '{"k":0.}', "fraction part requires at least one digit"),
    ("number_trailing_junk", "2-", "trailing bytes after a bare number token"),
    ("case_insensitive_literal", "nuLl", "literals must be spelled exactly null/true/false"),
    ("unquoted_key", "{tz:true}", "object member names must be quoted strings"),
    ("short_u_escape", '"' + BS + 'u00es"', "backslash-u requires exactly 4 hex digits"),
    ("unknown_escape", '"a' + BS + 'qb"', "only the eight RFC 8259 escapes plus u are legal"),
]
# NOTE: invalid-UTF-8 rejection (the fuzzer's largest class) cannot be pinned here —
# the corpus input field is a JSON string, which cannot carry invalid byte sequences.
# That class is covered by differential_probe.py (raw-bytes cases) and the fuzzer.


def run_cli(lineage: str, payload: bytes):
    cli = ROOT / lineage / "bin" / "baion_canon_hash"
    p = subprocess.run([str(cli)], input=payload, capture_output=True)
    return p.returncode, p.stdout.decode().strip()


def main() -> int:
    pin_only = "--pin-only-uniform" in sys.argv
    accept_rows, failures = [], []
    for name, text in ACCEPT:
        payload = text.encode("utf-8")
        results = {L: run_cli(L, payload) for L in LINEAGES}
        codes = {L: r[0] for L, r in results.items()}
        hashes = {r[1] for r in results.values() if r[0] == 0}
        if any(codes.values()) or len(hashes) != 1:
            failures.append((name, results))
            if not pin_only:
                continue
            continue
        accept_rows.append({"name": name, "input": text, "sha256": hashes.pop()})

    (HERE / "accept.jsonl").write_text(
        "".join(json.dumps(r, ensure_ascii=True) + "\n" for r in accept_rows))
    (HERE / "reject.jsonl").write_text(
        "".join(json.dumps({"name": n, "input": t, "reason": why}, ensure_ascii=True) + "\n"
                for n, t, why in REJECT))

    print(f"pinned {len(accept_rows)}/{len(ACCEPT)} accept cases; {len(REJECT)} reject cases")
    for name, results in failures:
        detail = " ".join(f"{L}={'REJ' if r[0] else r[1][:8]}" for L, r in results.items())
        print(f"NOT PINNED (divergent/rejecting): {name}: {detail}")
    return 1 if (failures and not pin_only) else 0


if __name__ == "__main__":
    sys.exit(main())
