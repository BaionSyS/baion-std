#!/usr/bin/env python3
# BAION STD conformance runner — Observer for ONE CLI against the pinned corpus.
# Spec: repo README "Conformance corpus"; companion to verify_all_lineages.sh.
#
# WHY this exists: verify_all_lineages.sh requires all seven CLIs at once, so
# it cannot exercise a single instrumented build (sanitizer CI builds only the
# C or C++ lineage). This runner holds one CLI to the same corpus contract:
# every accept vector must hash to its pinned SHA-256, every reject vector
# must exit nonzero. Under ASan/UBSan with -fno-sanitize-recover, any
# undefined behavior on an admitted input aborts the CLI and fails the run.
#
# Usage: run_corpus_cli.py <path-to-baion_canon_hash>
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path-to-baion_canon_hash>", file=sys.stderr)
        return 2
    cli = Path(sys.argv[1])
    if not cli.exists():
        print(f"FAIL: CLI not found at {cli}", file=sys.stderr)
        return 1

    failures = 0

    for line in (HERE / "accept.jsonl").read_text().splitlines():
        case = json.loads(line)
        proc = subprocess.run(
            [str(cli)], input=case["input"].encode("utf-8"),
            capture_output=True, timeout=30,
        )
        got = proc.stdout.decode().strip()
        if proc.returncode != 0 or got != case["sha256"]:
            print(f"ACCEPT {case['name']}: FAIL "
                  f"(exit={proc.returncode}, got={got or '<empty>'}, "
                  f"want={case['sha256']}) stderr={proc.stderr.decode().strip()}")
            failures += 1
        else:
            print(f"ACCEPT {case['name']}: ok")

    for line in (HERE / "reject.jsonl").read_text().splitlines():
        case = json.loads(line)
        proc = subprocess.run(
            [str(cli)], input=case["input"].encode("utf-8"),
            capture_output=True, timeout=30,
        )
        # Reject contract is a clean nonzero exit — a sanitizer abort
        # (SIGABRT, negative returncode) is a crash, not a rejection.
        if proc.returncode <= 0:
            print(f"REJECT {case['name']}: FAIL (exit={proc.returncode})")
            failures += 1
        else:
            print(f"REJECT {case['name']}: ok")

    if failures:
        print(f"FAIL: {failures} corpus case(s) failed for {cli}")
        return 1
    print(f"PASS: corpus green for {cli}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
