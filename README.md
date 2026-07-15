# BAION STD — Cross-Lineage Canonical JSON + SHA-256

[![verify](https://github.com/BaionSyS/baion-std/actions/workflows/verify.yml/badge.svg?branch=main)](https://github.com/BaionSyS/baion-std/actions/workflows/verify.yml)

Seven independent implementations of the same canonicalization contract — C, C++, Rust, Go, D, Haskell, and OCaml — that produce **byte-identical canonical JSON and identical SHA-256 digests** for the supported JSON domain, enforced by shared conformance vectors and cross-lineage tests. Not "semantically equivalent." Identical bytes, identical hashes, every lineage.

```
./build_all.sh          # builds + tests all seven lineages, places every CLI
./verify_all_lineages.sh
```

`build_all.sh` builds each lineage with its native toolchain, runs its test suite, and places the CLI at `<lineage>/bin/baion_canon_hash` — the layout the verifier requires. `verify_all_lineages.sh` then pipes the same JSON documents into every CLI and diffs the hex, and additionally asserts that all seven **uniformly reject** inputs outside the supported domain (see below). All seven lineages must be present — a missing binary fails the run, and one byte of disagreement anywhere fails the run. Success prints `PASS: 7/7 lineages produced identical output`.

## Why this exists

BAION Systems builds multi-language systems where independently implemented components must agree on content-addressed storage keys. Each implementation canonicalizes a JSON document and hashes it; when independently implemented components compute the same digest for the same logical record, the digest can serve as a stable cross-language content identifier. Any mismatch becomes an immediate, testable conformance failure. That guarantee is only as good as the discipline that seven compilers, seven standard libraries, and seven JSON ecosystems emit the *same bytes* — this repository is that discipline, with tests.

The interesting engineering is in the edge cases: key ordering, number formatting (integer vs. float boundaries), UTF-8 escaping decisions, empty-container serialization. Each lineage's test suite pins these against a shared conformance fixture (`conformance_reference.json`), and the verifier proves the lineages against each other.

## Supported JSON domain

Cross-lineage byte-identity is enforced and tested for:

- objects (member names must be **unique** — see below), arrays, strings (full UTF-8, including multi-byte and escaped control characters **except U+0000**), booleans, null
- integers within the IEEE-754 exact range (±2⁵³)
- floats whose canonical form is pinned by the conformance vectors (including integer-valued floats, which serialize without a trailing `.0` per RFC 8785 §3.2.2.3 — `1.0` canonicalizes to `1` in every lineage, enforced by the verifier)

**Uniformly rejected:** two input classes are refused with a nonzero exit by all seven CLIs, and the verifier asserts the rejection is uniform:

- *Strings containing U+0000* (as the escape `\u0000` or a raw NUL byte). One lineage cannot represent embedded NUL losslessly, and accepting it anywhere would allow silent canonicalization collisions. A literal backslash followed by the text `u0000` (JSON `\\u0000`) is not a NUL and canonicalizes normally.
- *Objects with duplicate member names*, at any nesting depth. RFC 8259 leaves duplicate-name behavior undefined, and the seven JSON ecosystems genuinely diverge (keep-first, keep-last, keep-both) — so object member names must be unique. Duplicates are detected on the *decoded* name: `{"a":1,"\u0061":2}` is rejected because `\u0061` decodes to `a`.

**Known exclusions** (documented honestly because they are where seven ecosystems genuinely differ): number formatting outside the pinned vectors — very large integers beyond 2⁵³, negative zero, and scientific-notation thresholds — is not yet normalized across all seven lineages and must not be relied on. Non-finite numbers (NaN, ±Inf) are not valid JSON and are rejected or nulled per lineage test suites. If your data stays in the supported domain, the byte-identity guarantee holds; the conformance fixture is the authoritative definition of that domain.

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
