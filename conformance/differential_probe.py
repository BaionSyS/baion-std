#!/usr/bin/env python3
# BAION STD differential probe — Observer (agreement-only fuzz over danger zones)
# Spec: repo README "Supported JSON domain"; corpus-as-data refactor (harden-v0.2.0).
#
# WHY this exists: the pinned corpus (accept.jsonl/reject.jsonl) proves the
# lineages agree on KNOWN vectors; this probe generates a deterministic sweep
# of the danger zones (number bands, escape forms, structure edges) and fails
# if the seven CLIs disagree on ANY case — either a split accept/reject
# decision or two different hashes. No pinned hashes here: agreement is the
# only assertion, so new divergences surface as failures instead of silently
# waiting for a reviewer to find them. Deterministic by construction (no
# randomness) so CI failures are reproducible.
#
# Inputs are built as Python strings and encoded to UTF-8; escape-sensitive
# cases are assembled from chr()/concatenation so no editor can decode them.
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
LINEAGES = ["c", "cpp", "rust", "go", "d", "haskell", "ocaml"]

BS = chr(0x5C)  # backslash, kept out of literals so editors can't decode escapes


def plain_decimal(digits: str, exp10: int) -> str:
    """Write digits × 10^exp10 as a plain-decimal token (never exponent form)."""
    if exp10 >= 0:
        return digits + "0" * exp10
    if -exp10 < len(digits):
        return digits[:exp10] + "." + digits[exp10:]
    return "0." + "0" * (-exp10 - len(digits)) + digits


def build_cases():
    cases = []  # (name, input-text)

    # Integer tokens across magnitudes (in-domain and beyond ±2^53).
    for v in ["0", "-0", "1", "-1", "42", "-42", "9007199254740992",
              "-9007199254740992", "9007199254740993", "-9007199254740993",
              "99999999999999999999999999", "-99999999999999999999999999"]:
        cases.append((f"int_{v}", '{"x":' + v + "}"))
    for e in range(0, 24):
        cases.append((f"int_pow10_{e}", '{"x":1' + "0" * e + "}"))

    # Fraction tokens: d × 10^e written plainly, sweeping the whole band
    # including out-of-domain edges (which must uniformly reject).
    for digits in ["1", "15", "123456789"]:
        for e in range(-12, 23 - len("123456789")):
            tok = plain_decimal(digits, e)
            if "." not in tok:
                tok += ".0"  # force the fraction lexical class
            cases.append((f"frac_{digits}e{e}", '{"x":' + tok + "}"))
    for v in ["-0.0", "0.5", "-0.375", "0.1", "123.456", "3.141592653589793",
              "0.000001", "0.0000001", "1.7976931348623157", "2.220446049250313"]:
        cases.append((f"frac_{v}", '{"x":' + v + "}"))

    # Exponent spellings — outside the plain-decimal domain, must reject.
    for v in ["1e0", "1E0", "1e2", "1e-2", "1e-7", "1e21", "1e400", "-1e400",
              "1.5e3", "2E-6"]:
        cases.append((f"exp_{v}", '{"x":' + v + "}"))

    # Strings: escape zoo, NUL, surrogates, multibyte.
    cases.append(("str_escape_zoo",
                  '{"s":"a' + BS + 'n b' + BS + 't c' + BS + '" d' + BS + BS + ' e' + BS + '/"}'))
    cases.append(("str_nul_escape", '{"s":"a' + BS + 'u0000b"}'))          # reject
    cases.append(("str_literal_backslash_u0000", '{"s":"a' + BS + BS + 'u0000b"}'))
    cases.append(("str_lone_high_surrogate", '{"s":"' + BS + 'ud800"}'))   # reject
    cases.append(("str_lone_low_surrogate", '{"s":"' + BS + 'udc00"}'))    # reject
    cases.append(("str_surrogate_pair_escape", '{"s":"' + BS + 'ud83d' + BS + 'ude00"}'))
    cases.append(("str_raw_emoji", '{"s":"\U0001F600"}'))
    cases.append(("str_escaped_a_vs_raw_key", '{"a":1,"' + BS + 'u0061":2}'))  # reject (dup)
    cases.append(("str_noncharacter", '{"s":"￿"}'))
    cases.append(("str_control_escapes", '{"s":"' + BS + 'u0001' + BS + 'u001f"}'))
    cases.append(("str_long", '{"s":"' + "xy" * 512 + '"}'))

    # Raw control bytes: rejected inside strings (RFC 8259 §7 requires the
    # escape), and outside strings only 0x09/0x0A/0x0D/0x20 are whitespace.
    for b in [0x01, 0x02, 0x09, 0x0A, 0x0D, 0x1E, 0x1F]:
        cases.append((f"str_raw_ctrl_{b:02x}", '{"s":"a' + chr(b) + 'b"}'))  # reject
        cases.append((f"key_raw_ctrl_{b:02x}", '{"a' + chr(b) + '":1}'))     # reject
    for b in [0x01, 0x02, 0x0B, 0x0C, 0x1F]:
        cases.append((f"ws_raw_ctrl_{b:02x}", '{"a":1,' + chr(b) + '"b":2}'))  # reject
    cases.append(("ws_tab_between_tokens", '{"a":' + chr(0x09) + '1}'))   # legal ws
    cases.append(("ws_crlf_framing", chr(0x0D) + chr(0x0A) + '{"a":1}' + chr(0x0D) + chr(0x0A)))

    # Raw invalid UTF-8 (bytes payloads — cannot be expressed as str). One
    # lineage replaced bad bytes with U+FFFD and hashed the result: a silent
    # cross-lineage collision, the worst divergence class. Uniform reject.
    Q, OPEN, CLOSE = b'"', b'{"', b'":[]}'
    cases.append(("utf8_stray_lead", OPEN + bytes([0xE0]) + b"a" + CLOSE))          # reject
    cases.append(("utf8_stray_continuation", Q + b"a" + bytes([0x85]) + b"b" + Q))  # reject
    cases.append(("utf8_overlong_slash", Q + bytes([0xC0, 0xAF]) + Q))              # reject
    cases.append(("utf8_encoded_surrogate", Q + bytes([0xED, 0xA0, 0x80]) + Q))     # reject
    cases.append(("utf8_truncated_2byte", Q + b"a" + bytes([0xC3]) + Q))            # reject
    cases.append(("utf8_beyond_10ffff", Q + bytes([0xF4, 0x90, 0x80, 0x80]) + Q))   # reject
    cases.append(("utf8_f5_lead", Q + bytes([0xF5, 0x80, 0x80, 0x80]) + Q))         # reject
    cases.append(("utf8_valid_2byte", '{"x":"é"}'))                                 # accept
    cases.append(("utf8_valid_4byte", '{"x":"\U0001F600"}'))                        # accept

    # Number-token grammar edges (RFC 8259: int = 0 / [1-9]digits; frac needs a digit).
    for v in ["0635", "-004", "01", "007", "03000000000000004"]:
        cases.append((f"num_leadzero_{v}", v))                            # reject
    for v in ["0.", "01.", ".5", "-.5", "+1", "-", "2-", "1-", "77-7957", "0635.5"]:
        cases.append((f"num_malformed_{v}", v))                           # reject
    cases.append(("num_zero_frac_ok", '{"x":0.25}'))                      # accept

    # Literal spellings must be exact.
    for v in ["nuLl", "falSe", "tRue", "TRUE", "nul", "truee"]:
        cases.append((f"lit_{v}", v))                                     # reject

    # Non-JSON extensions some parsers allow: comments, non-finite literals.
    cases.append(("line_comment", '{"a":1} // note'))                     # reject
    cases.append(("line_comment_inside", '{"a": // note\n1}'))            # reject
    cases.append(("block_comment", '{"a":/* note */1}'))                  # reject
    for v in ["NaN", "Infinity", "-Infinity", "True", "None"]:
        cases.append((f"nonfinite_{v}", '{"x":' + v + "}"))               # reject
    cases.append(("nan_in_string_ok", '{"x":"NaN // fine"}'))             # accept

    # Structure lexing: unquoted keys, malformed escapes.
    cases.append(("unquoted_key", "{tz:true}"))                           # reject
    cases.append(("short_u_escape", '"' + BS + 'u00es"'))                 # reject
    cases.append(("short_u_surrogate", '"' + BS + 'ud83' + BS + 'ude00"'))  # reject
    cases.append(("unknown_escape_q", '"a' + BS + 'qb"'))                 # reject
    cases.append(("escape_at_eof", '"a' + BS))                            # reject

    # Integer-valued doubles beyond 2^53 entering via fraction tokens:
    # canonical form is ES-262 SHORTEST digits, not the exact integer value.
    cases.append(("big_float_shortest", "65219416364867774.9377591"))     # accept, one hash
    cases.append(("big_float_shortest_2", '{"x":9007199254740993.5}'))
    cases.append(("big_float_shortest_3", "123456789012345678.9"))

    # Structure: duplicates, depth, document framing.
    cases.append(("dup_toplevel", '{"a":1,"a":2}'))                # reject
    cases.append(("dup_nested", '{"x":{"b":1,"b":2}}'))            # reject
    cases.append(("dup_in_array", '[{"k":1,"k":2}]'))              # reject
    cases.append(("sibling_same_key", '[{"k":1},{"k":2}]'))
    cases.append(("deep_nest_60", ('{"a":' * 60) + "1" + ("}" * 60)))
    cases.append(("bom_prefix", chr(0xFEFF) + '{"a":1}'))          # reject
    cases.append(("trailing_garbage", '{"a":1} x'))                # reject
    cases.append(("two_documents", '{"a":1}{"b":2}'))              # reject
    cases.append(("trailing_comma", '{"a":1,}'))                   # reject
    cases.append(("empty_input", ""))                              # reject
    cases.append(("surrounding_whitespace", '  {"a":1}  '))
    cases.append(("newline_framing", '\n{"a":1}\n'))
    for bare in ['"hi"', "true", "false", "null", "1", "1.5", "[]", "{}"]:
        cases.append((f"bare_{bare[:6]}", bare))
    return cases


def run_cli(lineage: str, payload: bytes):
    cli = ROOT / lineage / "bin" / "baion_canon_hash"
    p = subprocess.run([str(cli)], input=payload, capture_output=True)
    return p.returncode, p.stdout.decode(errors="replace").strip()


def main() -> int:
    cases = build_cases()
    divergent = []
    for name, text in cases:
        payload = text.encode("utf-8") if isinstance(text, str) else text
        results = {L: run_cli(L, payload) for L in LINEAGES}
        accepts = {L for L, (rc, _) in results.items() if rc == 0}
        if accepts and accepts != set(LINEAGES):
            divergent.append((name, "accept/reject split", results))
            continue
        hashes = {h for rc, h in results.values() if rc == 0}
        if len(hashes) > 1:
            divergent.append((name, "hash split", results))

    print(f"probed {len(cases)} cases across {len(LINEAGES)} lineages: "
          f"{len(divergent)} divergent")
    for name, kind, results in divergent:
        print(f"DIVERGE ({kind}): {name}")
        for L, (rc, h) in results.items():
            print(f"    {L:8s} {'REJECT' if rc else h}")
    return 1 if divergent else 0


if __name__ == "__main__":
    sys.exit(main())
