# BAION STD (public cut) — OCaml lineage build
# Canonical JSON + SHA-256 subset only.

# WHY: `make` runs in a non-interactive shell that does not source ~/.bashrc
# or opam env, so dune (installed via opam) may not be on PATH. `opam exec --`
# runs the command with opam env loaded. Override DUNE=dune if dune is
# already on PATH (e.g. CI images with a system dune).
DUNE ?= opam exec -- dune

# WHY: the conformance fixture is shared across all seven lineage cuts and
# lives one directory above this repo; a per-repo copy would drift.
BAION_CONFORMANCE_REF ?= ../conformance_reference.json

.PHONY: all build test clean

all: build test

build:
	$(DUNE) build
	mkdir -p bin
	cp -f _build/default/cli/baion_canon_hash.exe bin/baion_canon_hash

test: build
	BAION_CONFORMANCE_REF=$(BAION_CONFORMANCE_REF) \
		./_build/default/test/conformance_test.exe

clean:
	rm -rf _build bin/baion_canon_hash
