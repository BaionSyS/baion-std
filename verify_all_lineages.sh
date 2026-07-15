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
  '{"x":1.0}'
  '1.0'
  '{"x":"a\\u0000b"}'
)

# Inputs every lineage must UNIFORMLY REJECT (nonzero exit).
# U+0000: outside the supported domain because one lineage cannot represent it losslessly —
# accepting it anywhere would allow silent canonicalization collisions.
# Duplicate object keys: RFC 8259 leaves duplicate-name behavior undefined and the seven
# ecosystems genuinely diverge (keep-first / keep-last / keep-both), so member names must
# be unique; duplicates compare on the DECODED name (third duplicate vector spells the
# same key as an escape).
reject_inputs=(
  '{"x":"a\u0000b"}'
  '{"a\u0000":1}'
  '{"a":1,"a":2}'
  '{"x":{"b":1,"b":2}}'
  '{"a":1,"\u0061":2}'
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

# Uniform-rejection pass: every lineage must refuse these with nonzero exit.
for i in "${!reject_inputs[@]}"; do
  echo "reject $i: ${reject_inputs[$i]}"
  for L in "${LINEAGES[@]}"; do
    if printf '%s' "${reject_inputs[$i]}" | "$HERE/$L/bin/baion_canon_hash" >/dev/null 2>&1; then
      printf '  BAD   %-8s accepted input it must reject\n' "$L"
      fail=1
    else
      printf '  REJECT %-7s ok\n' "$L"
    fi
  done
done

if [ "$fail" -eq 0 ]; then
  echo "PASS: $EXPECTED/$EXPECTED lineages produced identical output"
else
  echo "FAIL: byte-identity failure"
fi
exit $fail
