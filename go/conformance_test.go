package baionstd

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// Cross-implementation conformance tests — verify byte-identical canonical
// JSON and identical SHA-256 output against the shared fixture
// testdata/conformance_reference.json (byte-identical copy of the fixture at
// the repository root, shared by all language implementations).

func loadConformanceRef(t *testing.T) map[string]interface{} {
	t.Helper()
	data, err := os.ReadFile("testdata/conformance_reference.json")
	if err != nil {
		t.Fatalf("read conformance_reference.json: %v", err)
	}
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.UseNumber()
	var ref map[string]interface{}
	if err := dec.Decode(&ref); err != nil {
		t.Fatalf("parse conformance_reference.json: %v", err)
	}
	return ref
}

// checkDocument canonicalizes the fixture input named key, compares against
// the fixture's expected canonical string, then compares the SHA-256 of the
// canonical bytes against the fixture's expected digest.
func checkDocument(t *testing.T, key string) {
	t.Helper()
	ref := loadConformanceRef(t)

	input, ok := ref[key]
	if !ok {
		t.Fatalf("fixture missing key %s", key)
	}
	got := CanonicalizeJSON(input)

	want, ok := ref[key+"_canonical_json"].(string)
	if !ok {
		t.Fatalf("fixture missing key %s_canonical_json", key)
	}
	if got != want {
		t.Fatalf("%s — canonical JSON not byte-identical\nwant: %s\ngot:  %s", key, want, got)
	}

	wantHash, ok := ref[key+"_sha256_hex"].(string)
	if !ok {
		t.Fatalf("fixture missing key %s_sha256_hex", key)
	}
	sum := sha256.Sum256([]byte(got))
	gotHash := hex.EncodeToString(sum[:])
	if gotHash != wantHash {
		t.Fatalf("%s — SHA-256 mismatch\nwant: %s\ngot:  %s", key, wantHash, gotHash)
	}
}

func TestConformance_ReferenceDocument(t *testing.T) {
	checkDocument(t, "reference_document")
}

func TestConformance_ReferenceDocumentUnicode(t *testing.T) {
	checkDocument(t, "reference_document_unicode")
}

func TestConformance_ReferenceDocumentEdges(t *testing.T) {
	checkDocument(t, "reference_document_edges")
}

// Plain SHA-256 vector: digest of a fixed input string, independent of
// canonicalization, to pin the hash implementation itself.
func TestConformance_SHA256Hex(t *testing.T) {
	ref := loadConformanceRef(t)

	input := ref["reference_sha256_input"].(string)
	h := sha256.Sum256([]byte(input))
	got := hex.EncodeToString(h[:])
	want := ref["reference_sha256_hex"].(string)

	if got != want {
		t.Fatalf("SHA-256 hex mismatch\nwant: %s\ngot:  %s", want, got)
	}
}

// Integer-valued floats — canonicalize without trailing decimal
// (fixed 2026-05-04: earlier float formatting diverged from RFC 8785).
// Build the value programmatically with explicit float64-tagged numbers so
// the canonicalizer never sees them as integers in the native type system.
func TestConformance_IntegerValuedFloats(t *testing.T) {
	ref := loadConformanceRef(t)

	// Build {"frac":1.5,"neg":-7.0,"vals":[1.0,2.0,3.0]} with each number
	// explicitly typed as float64. CanonicalizeJSON must strip ".0" from
	// integer-valued floats.
	v := map[string]interface{}{
		"frac": 1.5,
		"neg":  -7.0,
		"vals": []interface{}{1.0, 2.0, 3.0},
	}
	got := CanonicalizeJSON(v)
	want := ref["reference_integer_valued_floats_canonical_json"].(string)

	if got != want {
		t.Fatalf("integer-valued-float stripping mismatch\nwant: %s\ngot:  %s", want, got)
	}
}
