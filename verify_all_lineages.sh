#!/usr/bin/env bash
# BAION STD — Cross-Lineage Byte-Identity Verifier
# Feeds identical JSON inputs to every lineage's baion_canon_hash CLI and
# asserts all SEVEN lineages emit the same SHA-256 of the same canonical
# bytes. A missing CLI is a FAILURE, not a skip: partial participation
# would let the strongest claim in this repo pass vacuously.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LINEAGES=(c cpp rust go d haskell ocaml)
EXPECTED=${#LINEAGES[@]}

inputs=(
  '{"b":1,"a":[1,2]}'
  '{"z":1,"a":"é"}'
  '{"nested":{"y":[true,false,null],"x":0.5},"empty":{},"arr":[]}'
  '{"é":1,"e":2,"zß":"straße"}'
  '{"escapes":"line\nbreak\ttab \"quoted\" back\\slash"}'
  '{"max_safe":9007199254740992,"neg":-42,"empty":""}'
  '{"deep":{"a":{"b":{"c":[1,{"d":[]}]}}}}'
)

fail=0
missing=0
for L in "${LINEAGES[@]}"; do
  if [ ! -x "$HERE/$L/bin/baion_canon_hash" ]; then
    echo "MISSING $L (no CLI at $L/bin/baion_canon_hash — build it first; see README)"
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "FAIL: all $EXPECTED lineages must be built before verification"
  exit 1
fi

for i in "${!inputs[@]}"; do
  ref=""
  echo "input $i: ${inputs[$i]}"
  for L in "${LINEAGES[@]}"; do
    h="$(printf '%s' "${inputs[$i]}" | "$HERE/$L/bin/baion_canon_hash")" || { echo "  ERROR $L exited nonzero"; fail=1; continue; }
    [ -z "$ref" ] && ref="$h"
    if [ "$h" = "$ref" ]; then
      printf '  MATCH %-8s %s\n' "$L" "$h"
    else
      printf '  DIFF  %-8s %s\n' "$L" "$h"
      fail=1
    fi
  done
done

# Fixture file pass — the full cross-lineage conformance reference.
ref=""
echo "fixture: conformance_reference.json"
for L in "${LINEAGES[@]}"; do
  h="$("$HERE/$L/bin/baion_canon_hash" < "$HERE/conformance_reference.json")" || { echo "  ERROR $L on fixture"; fail=1; continue; }
  [ -z "$ref" ] && ref="$h"
  if [ "$h" = "$ref" ]; then printf '  MATCH %-8s %s\n' "$L" "$h"; else printf '  DIFF  %-8s %s\n' "$L" "$h"; fail=1; fi
done

if [ "$fail" -eq 0 ]; then
  echo "PASS: $EXPECTED/$EXPECTED lineages produced identical output"
else
  echo "FAIL: byte-identity failure"
fi
exit $fail
