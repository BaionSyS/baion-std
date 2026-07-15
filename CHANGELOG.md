# Changelog

## v0.2.1 — 2026-07-15

Corrective release. v0.2.0 remains published and tagged — this release
supersedes it rather than replacing it (found → preserved → corrected →
tested → superseded).

### Fixed

- **C lineage undefined behavior on admitted input** (`c/src/canonical_json.c`,
  `write_number`): the integer fast-path evaluated `(double)(long long)d`
  *before* its `fabs(d) < 1e15` range guard. For integer-valued fraction
  tokens ≥ 2⁶³ inside the supported domain (e.g. `100000000000000000000.0`,
  |v| < 10²¹), the double→`long long` conversion is undefined behavior
  (C11 §6.3.1.4p1), caught by UBSan
  (`runtime error: 1e+20 is outside the range of representable values of
  type 'long long int'`). On tested x86-64 builds the conversion saturated
  and the code fell through to the correct big-integer branch, so all seven
  lineages agreed on the affected inputs — no known wrong hash was ever
  produced — but undefined behavior is not a cross-platform contract. The
  guard now runs before any conversion (`fabs(d) < 1e15 && trunc(d) == d`),
  the same order the C++ lineage already used.

### Added

- Regression vector `huge_integer_valued_float`
  (`{"x":100000000000000000000.0}`) pinned in the conformance corpus;
  all seven lineages agree (25 accept + 31 reject vectors green).
- Sanitizer CI gate for the two memory-unsafe lineages (C, C++):
  ASan + UBSan + float-cast-overflow with `-fno-sanitize-recover=all`,
  running each lineage's tests and the full corpus through the
  instrumented CLI (`conformance/run_corpus_cli.py`).

### Hardened

- C string buffer: allocation failures now latch an OOM flag and
  `baion_canonicalize_json` returns NULL (defined failure — never a
  partial canonical string, never a write through a failed allocation);
  `realloc` no longer assigned directly to the live pointer; capacity
  growth guarded against `size_t` overflow; the object-key sort array
  allocation is checked.
- Supply chain: workflow declares least-privilege
  `permissions: contents: read`; every job has a timeout; cJSON is
  fetched by commit SHA (`acc76239…`, the commit behind v1.7.18) instead
  of a movable tag; CI toolchains pinned to exact versions (Rust 1.94.0,
  DMD 2.112.0, GHC 9.6.7, cabal 3.16.1.0, pinned opam package versions);
  `rust/Cargo.lock` and `haskell/cabal.project.freeze` now committed.

### Known remaining limits (documented, not yet enforced)

- No enforced caps on input size, nesting depth, or member counts.
  Resource limits change which documents are *rejected*, so they are a
  cross-lineage contract change — all seven lineages must adopt identical
  limits in the same release. Planned for a future minor version; until
  then, treat the CLIs as trusted-input tools.
- The C number writer assumes the process stays in the default `C`
  locale (documented in-source).

## v0.2.0 — 2026-07-15

Cross-lineage hardening release: uniform rejection contract (invalid
UTF-8, raw controls, malformed escapes/tokens, duplicate keys, U+0000,
BOM, number domain), corpus-as-data conformance, seeded fuzz agreement
layer, ES-262 shortest-digits fix. Breaking: previously-accepted lax
inputs are now uniformly rejected. See the GitHub release notes.

## v0.1.3 — 2026-07-15

Uniform rejection of duplicate object keys across all seven lineages.

## v0.1.2 — 2026-07-15

Canonicalization contract round: uniform U+0000 rejection, Go number
normalization, `build_all.sh`, verifier reject-vectors (external review
round 2).

## v0.1.1 — 2026-07-15

Initial public release: seven-lineage canonical JSON + SHA-256,
byte-identity verified.
