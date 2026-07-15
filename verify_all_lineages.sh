#!/usr/bin/env bash
# BAION STD — Cross-Lineage Byte-Identity Verifier (corpus-driven)
# Feeds every conformance-corpus input to every lineage's baion_canon_hash CLI.
# Accept cases must hash to the corpus-PINNED SHA-256 in all SEVEN lineages;
# reject cases must exit nonzero in all seven. A missing CLI is a FAILURE,
# not a skip: partial participation would let the strongest claim in this
# repo pass vacuously.
#
# Vectors live in conformance/accept.jsonl + conformance/reject.jsonl (one
# JSON object per line; inputs are JSON-escaped strings so escape-sensitive
# bytes — NUL, BOM, lone surrogates — survive text editing losslessly).
# Regenerate/extend via conformance/gen_corpus.py, which refuses to pin any
# accept case the seven current CLIs disagree on. This script never invents
# an expected hash: pins come only from the corpus.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LINEAGES=(c cpp rust go d haskell ocaml)
EXPECTED=${#LINEAGES[@]}
ACCEPT="$HERE/conformance/accept.jsonl"
REJECT="$HERE/conformance/reject.jsonl"

fail=0
missing=0
for L in "${LINEAGES[@]}"; do
  if [ ! -x "$HERE/$L/bin/baion_canon_hash" ]; then
    echo "MISSING $L (no CLI at $L/bin/baion_canon_hash — build it first; see README)"
    missing=1
  fi
done
for f in "$ACCEPT" "$REJECT"; do
  if [ ! -f "$f" ]; then
    echo "MISSING corpus file $f (run conformance/gen_corpus.py)"
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "FAIL: all $EXPECTED lineages and both corpus files are required"
  exit 1
fi

# Decode each corpus row to "name<TAB>base64(input-bytes)<TAB>sha256" — base64
# because the raw input bytes may contain NUL/BOM, which bash variables and
# command substitution cannot carry.
corpus_rows() {
  python3 - "$1" <<'PY'
import base64, json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    payload = base64.b64encode(row["input"].encode("utf-8")).decode("ascii")
    print(f'{row["name"]}\t{payload}\t{row.get("sha256", "")}')
PY
}

# Accept pass: pinned-hash agreement across all seven lineages.
n_accept=0
while IFS=$'\t' read -r name b64 pin; do
  n_accept=$((n_accept + 1))
  echo "accept: $name"
  for L in "${LINEAGES[@]}"; do
    h="$(printf '%s' "$b64" | base64 -d | "$HERE/$L/bin/baion_canon_hash")" \
      || { echo "  ERROR $L exited nonzero"; fail=1; continue; }
    if [ "$h" = "$pin" ]; then
      printf '  MATCH %-8s %s\n' "$L" "$h"
    else
      printf '  DIFF  %-8s %s (pinned %s)\n' "$L" "$h" "$pin"
      fail=1
    fi
  done
done < <(corpus_rows "$ACCEPT")

# Fixture file pass — the full cross-lineage conformance reference.
ref=""
echo "fixture: conformance_reference.json"
for L in "${LINEAGES[@]}"; do
  h="$("$HERE/$L/bin/baion_canon_hash" < "$HERE/conformance_reference.json")" || { echo "  ERROR $L on fixture"; fail=1; continue; }
  [ -z "$ref" ] && ref="$h"
  if [ "$h" = "$ref" ]; then printf '  MATCH %-8s %s\n' "$L" "$h"; else printf '  DIFF  %-8s %s\n' "$L" "$h"; fail=1; fi
done

# Reject pass: every lineage must refuse these with nonzero exit. Reasons are
# documented per-row in reject.jsonl.
n_reject=0
while IFS=$'\t' read -r name b64 _; do
  n_reject=$((n_reject + 1))
  echo "reject: $name"
  for L in "${LINEAGES[@]}"; do
    if printf '%s' "$b64" | base64 -d | "$HERE/$L/bin/baion_canon_hash" >/dev/null 2>&1; then
      printf '  BAD   %-8s accepted input it must reject\n' "$L"
      fail=1
    else
      printf '  REJECT %-7s ok\n' "$L"
    fi
  done
done < <(corpus_rows "$REJECT")

if [ "$n_accept" -eq 0 ] || [ "$n_reject" -eq 0 ]; then
  echo "FAIL: corpus is empty (accept=$n_accept reject=$n_reject) — refusing a vacuous pass"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: $EXPECTED/$EXPECTED lineages agree on $n_accept accept + $n_reject reject vectors"
else
  echo "FAIL: byte-identity failure"
fi
exit $fail
