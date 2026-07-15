#!/usr/bin/env python3
# BAION STD agreement fuzzer — Observer (randomized adversarial sweep)
# Spec: repo README "Supported JSON domain"; harden-v0.2.0 conformance suite.
#
# WHY this exists: the corpus pins known vectors and differential_probe.py
# sweeps hand-enumerated danger zones; this fuzzer generates cases nobody
# thought of. Three attack classes: (1) structured documents biased toward
# the domain boundaries (2^53, 1e-6/1e21, surrogate range, escape forms),
# (2) byte-level mutations of valid documents, (3) raw garbage. For every
# input the seven CLIs must agree — all accept with one hash, or all reject
# — and none may die on a signal. The RNG is seeded from argv so any failure
# reproduces exactly: rerun with the same seed and case index.
#
# Usage: fuzz_agreement.py [seed] [n_structured] [n_mutation] [n_garbage]
import random
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
LINEAGES = ["c", "cpp", "rust", "go", "d", "haskell", "ocaml"]
BS = chr(0x5C)

BOUNDARY_INTS = [0, 1, -1, 2**53, -(2**53), 2**53 - 1, 2**53 + 1,
                 2**63, 2**64, 10**20, 10**21, 999, -42]
BOUNDARY_FRACTION_TEXTS = [
    "0.000001", "0.0000001", "0.0000015", "0.00001", "0.1", "0.5",
    "123.456", "-0.375", "-0.0", "0.0", "1.0", "3.141592653589793",
    "100000000000000000000.5", "999999999999999999999.9",
    "0.30000000000000004", "1.7976931348623157",
]
NASTY_STRING_PARTS = [
    "plain", "sp ace", "é", "ß", "中文", "\U0001F600",
    "�", "￿", "line1\nline2", "tab\there", 'quo"te', "back" + BS + "slash",
    BS + "n", BS + "t", BS + '"', BS + BS, BS + "/", BS + "u0041",
    BS + "u00e9", BS + "ud83d" + BS + "ude00",  # escape TEXT, inserted raw
    BS + "u0000", BS + "ud800", BS + "udc00",   # must force uniform rejection
    BS + BS + "u0000", BS + BS + "ud800",       # literal-backslash forms: fine
    "e", "E", "1e5", "-0.0", "null", "true", "9007199254740993",
]


def rand_key(rng, depth):
    kind = rng.randrange(6)
    if kind == 0:
        return "k%d" % rng.randrange(1000)
    if kind == 1:
        return rng.choice(["a", "b", "aa", "ab", "z", "é", "e"])
    if kind == 2:
        return ""
    if kind == 3:
        return rng.choice(NASTY_STRING_PARTS)
    if kind == 4:
        return "k" + str(depth)
    return "".join(rng.choice("abz09_") for _ in range(rng.randrange(1, 9)))


def rand_number_text(rng):
    kind = rng.randrange(5)
    if kind == 0:
        return str(rng.choice(BOUNDARY_INTS))
    if kind == 1:
        return rng.choice(BOUNDARY_FRACTION_TEXTS)
    if kind == 2:
        return str(rng.randrange(-10**6, 10**6))
    if kind == 3:  # random plain fraction, digit-built (no float formatting)
        whole = str(rng.randrange(0, 10**rng.randrange(1, 18)))
        frac = "".join(rng.choice("0123456789") for _ in range(rng.randrange(1, 12)))
        return ("-" if rng.random() < 0.4 else "") + whole + "." + frac
    # exponent spellings — outside the domain, must uniformly reject
    return "%d%s%d" % (rng.randrange(1, 999), rng.choice("eE"),
                       rng.randrange(-400, 400))


def rand_string_text(rng):
    n = rng.randrange(0, 5)
    return "".join(rng.choice(NASTY_STRING_PARTS) for _ in range(n))


def rand_value_text(rng, depth):
    """Build JSON source TEXT directly (not via json.dumps) so escape
    sequences land in the document as typed, exactly like hostile input."""
    if depth > 5 or rng.random() < 0.3:
        leaf = rng.randrange(5)
        if leaf == 0:
            return rand_number_text(rng)
        if leaf == 1:
            return '"' + rand_string_text(rng) + '"'
        return rng.choice(["true", "false", "null"])
    if rng.random() < 0.5:
        n = rng.randrange(0, 5)
        items = ",".join(rand_value_text(rng, depth + 1) for _ in range(n))
        return "[" + items + "]"
    n = rng.randrange(0, 5)
    seen, members = set(), []
    for _ in range(n):
        k = rand_key(rng, depth)
        dup = rng.random() < 0.03  # occasionally inject a duplicate on purpose
        if k in seen and not dup:
            continue
        seen.add(k)
        members.append('"' + k + '":' + rand_value_text(rng, depth + 1))
    return "{" + ",".join(members) + "}"


def mutate(rng, data: bytes) -> bytes:
    buf = bytearray(data)
    for _ in range(rng.randrange(1, 4)):
        op = rng.randrange(4)
        if not buf:
            break
        i = rng.randrange(len(buf))
        if op == 0:
            buf[i] = rng.randrange(256)
        elif op == 1:
            del buf[i]
        elif op == 2:
            buf.insert(i, rng.randrange(256))
        else:
            j = rng.randrange(len(buf))
            buf[i], buf[j] = buf[j], buf[i]
    return bytes(buf)


def rand_garbage(rng) -> bytes:
    kind = rng.randrange(4)
    n = rng.randrange(0, 64)
    if kind == 0:
        return bytes(rng.randrange(256) for _ in range(n))
    if kind == 1:
        return bytes(rng.randrange(0x20, 0x7F) for _ in range(n))
    if kind == 2:  # JSON-ish token soup
        toks = ['{', '}', '[', ']', ':', ',', '"a"', '1', 'true', 'null',
                ' ', BS, '"', '1e', '-', '.', '0']
        return "".join(rng.choice(toks) for _ in range(n)).encode()
    return ("﻿" * rng.randrange(1, 3) + '{"a":1}').encode()


def run_cli(lineage: str, payload: bytes):
    cli = ROOT / lineage / "bin" / "baion_canon_hash"
    p = subprocess.run([str(cli)], input=payload, capture_output=True, timeout=20)
    return p.returncode, p.stdout.decode(errors="replace").strip()


def check(payload: bytes):
    """Return None if the seven agree and none crashed, else a report dict."""
    results = {L: run_cli(L, payload) for L in LINEAGES}
    crashed = {L: rc for L, (rc, _) in results.items() if rc < 0}
    if crashed:
        return {"kind": "crash", "results": results, "crashed": crashed}
    accepts = {L for L, (rc, _) in results.items() if rc == 0}
    if accepts and accepts != set(LINEAGES):
        return {"kind": "accept/reject split", "results": results}
    hashes = {h for rc, h in results.values() if rc == 0}
    if len(hashes) > 1:
        return {"kind": "hash split", "results": results}
    return None


def main() -> int:
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 20260715
    n_structured = int(sys.argv[2]) if len(sys.argv) > 2 else 4000
    n_mutation = int(sys.argv[3]) if len(sys.argv) > 3 else 3000
    n_garbage = int(sys.argv[4]) if len(sys.argv) > 4 else 1000
    rng = random.Random(seed)
    failures = []
    accepted = rejected = 0
    valid_pool = []

    def record(tag, idx, payload, report):
        failures.append((tag, idx, payload, report))
        print(f"FAIL {tag}#{idx} ({report['kind']}): "
              f"{payload[:80]!r}{'...' if len(payload) > 80 else ''}")
        for L, (rc, h) in report["results"].items():
            print(f"    {L:8s} {'rc=' + str(rc) if rc != 0 else h}")

    phases = [
        ("structured", n_structured,
         lambda: rand_value_text(rng, 0).encode("utf-8")),
        ("mutation", n_mutation,
         lambda: mutate(rng, rng.choice(valid_pool)) if valid_pool
         else rand_garbage(rng)),
        ("garbage", n_garbage, lambda: rand_garbage(rng)),
    ]
    for tag, count, gen in phases:
        for i in range(count):
            payload = gen()
            report = check(payload)
            if report is None:
                rc0, _ = run_cli(LINEAGES[0], payload)
                if rc0 == 0:
                    accepted += 1
                    if tag == "structured" and len(valid_pool) < 500:
                        valid_pool.append(payload)
                else:
                    rejected += 1
            else:
                record(tag, i, payload, report)
            if (i + 1) % 1000 == 0:
                print(f"  {tag}: {i + 1}/{count} "
                      f"(uniform-accept={accepted} uniform-reject={rejected} "
                      f"fail={len(failures)})", flush=True)

    total = n_structured + n_mutation + n_garbage
    print(f"seed={seed} cases={total} uniform-accept={accepted} "
          f"uniform-reject={rejected} FAILURES={len(failures)}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
