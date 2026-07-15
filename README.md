# BAION STD — Cross-Lineage Canonical JSON + SHA-256

[![verify](https://github.com/BaionSyS/baion-std/actions/workflows/verify.yml/badge.svg?branch=main)](https://github.com/BaionSyS/baion-std/actions/workflows/verify.yml)

Seven independent implementations of the same canonicalization contract — C, C++, Rust, Go, D, Haskell, and OCaml — that produce **byte-identical canonical JSON and identical SHA-256 digests** for the supported JSON domain, enforced by shared conformance vectors and cross-lineage tests. Not "semantically equivalent." Identical bytes, identical hashes, every lineage.

```
./build_all.sh          # builds + tests all seven lineages, places every CLI
./verify_all_lineages.sh
```

**Prerequisites** (one toolchain per lineage): a C compiler + `make`; CMake ≥ 3.20 + a C++17 compiler; Rust (`cargo`); Go ≥ 1.22; D (`dmd` + `dub`); GHC ≥ 9.6 + `cabal` (aeson ≥ 2.2 is fetched by cabal); OCaml ≥ 5.x + `dune` with `yojson`, `digestif`, `alcotest` (via opam); `python3` for the conformance tooling. A successful run ends with a 7/7 PASS table from `build_all.sh` and `PASS: 7/7 lineages agree ...` from the verifier, exit 0.

`build_all.sh` builds each lineage with its native toolchain, runs its test suite, and places the CLI at `<lineage>/bin/baion_canon_hash` — the layout the verifier requires. `verify_all_lineages.sh` then feeds every vector in the conformance corpus (`conformance/accept.jsonl` + `conformance/reject.jsonl`) to every CLI: accept vectors must hash to the corpus-pinned SHA-256 in all seven lineages, and reject vectors must be **uniformly refused** (see below). `conformance/differential_probe.py` additionally sweeps generated danger-zone cases (number bands, escape forms, document framing) and fails on any disagreement; both run in CI. All seven lineages must be present — a missing binary fails the run, and one byte of disagreement anywhere fails the run. Success prints `PASS: 7/7 lineages produced identical output`.

## Why this exists

BAION Systems builds multi-language systems where independently implemented components must agree on content-addressed storage keys. Each implementation canonicalizes a JSON document and hashes it; when independently implemented components compute the same digest for the same logical record, the digest can serve as a stable cross-language content identifier. Any mismatch becomes an immediate, testable conformance failure. That guarantee is only as good as the discipline that seven compilers, seven standard libraries, and seven JSON ecosystems emit the *same bytes* — this repository is that discipline, with tests.

The interesting engineering is in the edge cases: key ordering, number formatting (integer vs. float boundaries), UTF-8 escaping decisions, empty-container serialization. Each lineage's test suite pins these against a shared conformance fixture (`conformance_reference.json`), and the verifier proves the lineages against each other.

## Supported JSON domain

Cross-lineage byte-identity is enforced and tested for:

- objects (member names must be **unique** — see below), arrays, strings (full UTF-8, including multi-byte and escaped control characters **except U+0000**), booleans, null
- integers in the closed interval [−2⁵³, +2⁵³] (i.e. |n| ≤ 9007199254740992). Every integer in this interval is exactly representable in IEEE-754 binary64. Note this is one wider than JavaScript's `MAX_SAFE_INTEGER` (2⁵³ − 1): ±2⁵³ itself is admitted because it is exact and unambiguous *within this domain* — the neighboring value 2⁵³ + 1 (the first integer that would silently round to it) is rejected, so no two accepted integer tokens can collide
- floats in the **plain-decimal domain**: zero, or magnitude in [10⁻⁶, 10²¹), written without exponent notation; the canonical form is ECMAScript `ToString` (shortest round-trip digits, plain decimal) per RFC 8785 §3.2.2.3 — `1.0` → `1`, `-0.0` → `0`, `0.1` → `0.1`, in every lineage, enforced by the pinned corpus

**Uniformly rejected:** these input classes are refused with a nonzero exit by all seven CLIs, and the verifier asserts the rejection is uniform:

- *Strings containing U+0000* (as the escape `\u0000` or a raw NUL byte). One lineage cannot represent embedded NUL losslessly, and accepting it anywhere would allow silent canonicalization collisions. A literal backslash followed by the text `u0000` (JSON `\\u0000`) is not a NUL and canonicalizes normally.
- *Objects with duplicate member names*, at any nesting depth. RFC 8259 leaves duplicate-name behavior undefined, and the seven JSON ecosystems genuinely diverge (keep-first, keep-last, keep-both) — so object member names must be unique. Duplicates are detected on the *decoded* name: `{"a":1,"\u0061":2}` is rejected because `\u0061` decodes to `a`.
- *Numbers outside the plain-decimal domain*: exponent notation (`1e2` is rejected even though the value is in range — spell it `100`), integers beyond ±2⁵³, and fractions below 10⁻⁶ or at/above 10²¹. Seven number formatters genuinely disagree in exponent territory; the supported domain is exactly where byte-identity is provable, and inside it the output is normalized rather than excluded.
- *Unpaired surrogate escapes* (a `\ud800`–`\udbff` escape not immediately followed by a low half, or a lone `\udc00`–`\udfff`): not Unicode scalar values, and ecosystems differ on replacement behavior. A literal backslash followed by surrogate text (`\\ud800`) is ordinary content.
- *Anything other than exactly one JSON document*: a leading UTF-8 BOM, trailing non-whitespace, concatenated documents, trailing commas, or empty input.

**Known exclusions:** non-finite numbers (NaN, ±Inf) are not valid JSON and are rejected or nulled per lineage test suites. The conformance corpus (`conformance/accept.jsonl`, pinned hashes; `conformance/reject.jsonl`, uniform rejections; regenerated by `conformance/gen_corpus.py`, which refuses to pin any case the seven CLIs disagree on) is the authoritative definition of the supported domain. If your data stays in the supported domain, the byte-identity guarantee holds.

## Layout

`./build_all.sh` is the supported way to build everything. Per-lineage equivalents (each must end with the CLI at `<lineage>/bin/baion_canon_hash`):

| Dir | Lineage | Build + test + place CLI |
|-----|---------|--------------------------|
| `c/` | C | `make -C c build && make -C c test` |
| `cpp/` | C++ | `cmake -S cpp -B cpp/build && cmake --build cpp/build && ctest --test-dir cpp/build` |
| `rust/` | Rust | `cd rust && cargo build --release && cargo test --release && mkdir -p bin && cp target/release/baion_canon_hash bin/` |
| `go/` | Go | `cd go && go build -o bin/baion_canon_hash ./cmd/baion_canon_hash && go test ./...` |
| `d/` | D | `cd d && dub build --config=cli && dub build --config=unittest && ./bin/baionstd-canon-test` |
| `haskell/` | Haskell | `cd haskell && cabal build all && cabal test all && mkdir -p bin && cp "$(cabal list-bin baion-canon-hash)" bin/baion_canon_hash` |
| `ocaml/` | OCaml | `cd ocaml && make build test` |

Each lineage's `bin/baion_canon_hash` CLI: UTF-8 JSON on stdin, lowercase SHA-256 hex of the canonical bytes on stdout; inputs outside the supported domain exit nonzero.

## Provenance

This is a public excerpt of BAION's internal STD libraries (developed since March 2026). This repository is limited to canonical JSON serialization and SHA-256 hashing; BAION's unreleased coordination and transport implementations are not included. BAION Systems LLC holds U.S. Provisional Patent Application #64/042,046.

## License

MIT — see [LICENSE](LICENSE).
