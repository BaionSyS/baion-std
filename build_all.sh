#!/usr/bin/env bash
# BAION STD — build_all: build + test all seven lineages from a fresh checkout
# and place every CLI where verify_all_lineages.sh expects it
# (<lineage>/bin/baion_canon_hash). Run this, then ./verify_all_lineages.sh.
#
# Toolchains required on PATH: gcc/cc + cmake (C, C++), cargo (Rust),
# go (Go), dub+dmd/ldc (D), cabal+ghc (Haskell), opam+dune (OCaml).
# Each lineage is independent: a missing toolchain fails that lineage only,
# and the summary reports exactly which lineages are ready.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
declare -A RESULT

run_lineage() { # name, command-string
  local name="$1" cmd="$2"
  echo "==> $name"
  if (cd "$HERE" && bash -c "$cmd"); then
    if [ -x "$HERE/$1/bin/baion_canon_hash" ]; then
      RESULT[$name]=PASS
    else
      echo "    built but CLI missing at $1/bin/baion_canon_hash"
      RESULT[$name]=FAIL
    fi
  else
    RESULT[$name]=FAIL
  fi
}

run_lineage c '
  make -C c build && make -C c test'

run_lineage cpp '
  cmake -S cpp -B cpp/build && cmake --build cpp/build &&
  ctest --test-dir cpp/build --output-on-failure'

run_lineage rust '
  cd rust && cargo build --release && cargo test --release &&
  mkdir -p bin && cp target/release/baion_canon_hash bin/baion_canon_hash'

run_lineage go '
  cd go && go build -o bin/baion_canon_hash ./cmd/baion_canon_hash &&
  go test ./...'

run_lineage d '
  cd d && dub build --config=cli &&
  dub build --config=unittest && ./bin/baionstd-canon-test'

# BAION_CABAL_OPTS: escape hatch for hosts where GHC needs extra linker
# flags (e.g. --ghc-options="-L$HOME/.local/lib" for a user-local libgmp).
run_lineage haskell '
  cd haskell && cabal build all ${BAION_CABAL_OPTS:-} &&
  cabal test all ${BAION_CABAL_OPTS:-} --test-show-details=direct &&
  mkdir -p bin && cp "$(cabal list-bin baion-canon-hash)" bin/baion_canon_hash'

run_lineage ocaml '
  cd ocaml && make build test'

echo
fail=0
for L in c cpp rust go d haskell ocaml; do
  printf '%-8s %s\n' "$L" "${RESULT[$L]:-FAIL}"
  [ "${RESULT[$L]:-FAIL}" = PASS ] || fail=1
done
if [ "$fail" -eq 0 ]; then
  echo "ALL 7 LINEAGES BUILT — run ./verify_all_lineages.sh"
else
  echo "BUILD INCOMPLETE — fix the lineages marked FAIL above"
fi
exit $fail
