# BAION STD — Cross-Lineage Canonical JSON + SHA-256

Seven independent implementations of the same canonicalization contract — C, C++, Rust, Go, D, Haskell, and OCaml — that produce **byte-identical canonical JSON and identical SHA-256 digests** for the supported JSON domain, enforced by shared conformance vectors and cross-lineage tests. Not "semantically equivalent." Identical bytes, identical hashes, every lineage.

```
./verify_all_lineages.sh
```

pipes the same JSON documents into every lineage's compiled `baion_canon_hash` CLI and diffs the hex. All seven lineages must be present — a missing binary fails the run, and one byte of disagreement anywhere fails the run. Success prints `PASS: 7/7 lineages produced identical output`.

## Why this exists

BAION Systems builds multi-language systems where independently implemented components must agree on content-addressed storage keys. Each implementation canonicalizes a JSON document and hashes it; when independently implemented components compute the same digest for the same logical record, the digest can serve as a stable cross-language content identifier. Any mismatch becomes an immediate, testable conformance failure. That guarantee is only as good as the discipline that seven compilers, seven standard libraries, and seven JSON ecosystems emit the *same bytes* — this repository is that discipline, with tests.

The interesting engineering is in the edge cases: key ordering, number formatting (integer vs. float boundaries), UTF-8 escaping decisions, empty-container serialization. Each lineage's test suite pins these against a shared conformance fixture (`conformance_reference.json`), and the verifier proves the lineages against each other.

## Supported JSON domain

Cross-lineage byte-identity is enforced and tested for:

- objects, arrays, strings (full UTF-8, including multi-byte and escaped control characters), booleans, null
- integers within the IEEE-754 exact range (±2⁵³)
- floats whose canonical form is pinned by the conformance vectors (including integer-valued floats, which serialize without a trailing `.0` per RFC 8785 §3.2.2.3)

**Known exclusions** (documented honestly because they are where seven ecosystems genuinely differ): number formatting outside the pinned vectors — very large integers beyond 2⁵³, negative zero, and scientific-notation thresholds — is not yet normalized across all seven lineages and must not be relied on. Non-finite numbers (NaN, ±Inf) are not valid JSON and are rejected or nulled per lineage test suites. If your data stays in the supported domain, the byte-identity guarantee holds; the conformance fixture is the authoritative definition of that domain.

## Layout

| Dir | Lineage | Build |
|-----|---------|-------|
| `c/` | C | `make` |
| `cpp/` | C++ | cmake |
| `rust/` | Rust | `cargo build --release && cargo test` |
| `go/` | Go | `go build ./... && go test ./...` |
| `d/` | D | `dub build && dub test` |
| `haskell/` | Haskell | `cabal build && cabal test` |
| `ocaml/` | OCaml | `make` |

Each lineage builds a `bin/baion_canon_hash` CLI: UTF-8 JSON on stdin, lowercase SHA-256 hex of the canonical bytes on stdout.

## Provenance

This is a public excerpt of BAION's internal STD libraries (developed since March 2026). This repository is limited to canonical JSON serialization and SHA-256 hashing; BAION's unreleased coordination and transport implementations are not included. BAION Systems LLC holds U.S. Provisional Patent Application #64/042,046.

## License

MIT — see [LICENSE](LICENSE).
