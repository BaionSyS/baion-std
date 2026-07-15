package baionstd

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestCanonicalJSON_NestedSorting(t *testing.T) {
	// Verify keys are sorted at every nesting level, not just root.
	doc := map[string]interface{}{
		"z_key": map[string]interface{}{
			"beta":  json.Number("2"),
			"alpha": json.Number("1"),
		},
		"a_key": "first",
	}

	got := CanonicalizeJSON(doc)
	want := `{"a_key":"first","z_key":{"alpha":1,"beta":2}}`
	if got != want {
		t.Fatalf("nested sorting FAILED\nwant: %s\ngot:  %s", want, got)
	}
}

func TestCanonicalJSON_StringEscaping(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{"quotes", `he said "hello"`, `"he said \"hello\""`},
		{"backslash", `path\to\file`, `"path\\to\\file"`},
		{"newline", "line1\nline2", `"line1\nline2"`},
		{"tab", "col1\tcol2", `"col1\tcol2"`},
		{"forward_slash_not_escaped", "a/b/c", `"a/b/c"`},
		{"control_char", "null\x00byte", `"null\u0000byte"`},
		{"form_feed", "ff\fhere", `"ff\fhere"`},
		{"carriage_return", "cr\rhere", `"cr\rhere"`},
		{"backspace", "bs\bhere", `"bs\bhere"`},
		{"control_0x01", "soh\x01", `"soh\u0001"`},
		{"control_0x1f", "us\x1f", `"us\u001f"`},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var b strings.Builder
			writeJSONString(&b, tt.input)
			got := b.String()
			if got != tt.want {
				t.Errorf("escape %q\nwant: %s\ngot:  %s", tt.input, tt.want, got)
			}
		})
	}
}

func TestCanonicalJSON_NumberFormats(t *testing.T) {
	tests := []struct {
		name string
		val  interface{}
		want string
	}{
		{"int_zero", json.Number("0"), "0"},
		{"int_positive", json.Number("42"), "42"},
		{"int_negative", json.Number("-1"), "-1"},
		{"float", json.Number("3.14"), "3.14"},
		// json.Number preserves source spelling; canonicalization must decide
		// by numeric value (fixed 2026-07-15: raw-token passthrough kept "1.0"
		// and broke SHA-256 parity with every sibling lineage).
		{"number_trailing_zero", json.Number("1.0"), "1"},
		{"number_trailing_zero_2", json.Number("2.0"), "2"},
		{"number_neg_trailing_zero", json.Number("-7.0"), "-7"},
		{"number_exponent_integer", json.Number("1e0"), "1"},
		{"number_exponent_ten", json.Number("1e1"), "10"},
		{"number_frac_preserved", json.Number("1.5"), "1.5"},
		{"number_frac_leading_zero", json.Number("0.5"), "0.5"},
		{"number_plain_negative_int", json.Number("-7"), "-7"},
		// Integer tokens beyond 2^53 must keep full precision — the fix must
		// not route them through float64.
		{"number_big_int64", json.Number("9007199254740993"), "9007199254740993"},
		{"number_max_int64", json.Number("9223372036854775807"), "9223372036854775807"},
		{"number_max_uint64", json.Number("18446744073709551615"), "18446744073709551615"},
		{"go_int", int(7), "7"},
		{"go_int64", int64(100), "100"},
		{"go_float64_integer", float64(42), "42"},
		{"go_float64_frac", float64(1.5), "1.5"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := CanonicalizeJSON(tt.val)
			if got != tt.want {
				t.Errorf("number %v (%T)\nwant: %s\ngot:  %s", tt.val, tt.val, tt.want, got)
			}
		})
	}
}

func TestCanonicalJSON_ArrayPreservesOrder(t *testing.T) {
	arr := []interface{}{json.Number("3"), json.Number("1"), json.Number("2")}
	got := CanonicalizeJSON(arr)
	want := "[3,1,2]"
	if got != want {
		t.Fatalf("array order\nwant: %s\ngot:  %s", want, got)
	}
}

// Decoder-to-canonicalizer parity: what the real CLI path produces for the
// number spellings above, going through encoding/json with UseNumber exactly
// as cmd/baion_canon_hash does.
func TestCanonicalJSON_DecodedNumberNormalization(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{"object_trailing_zero", `{"x":1.0}`, `{"x":1}`},
		{"bare_trailing_zero", `1.0`, `1`},
		{"bare_exponent", `1e0`, `1`},
		{"frac_unchanged", `{"a":1.5,"b":0.5,"c":-7}`, `{"a":1.5,"b":0.5,"c":-7}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dec := json.NewDecoder(strings.NewReader(tt.input))
			dec.UseNumber()
			var v interface{}
			if err := dec.Decode(&v); err != nil {
				t.Fatalf("decode %q: %v", tt.input, err)
			}
			got, err := CanonicalizeJSONChecked(v)
			if err != nil {
				t.Fatalf("canonicalize %q: %v", tt.input, err)
			}
			if got != tt.want {
				t.Errorf("input %q\nwant: %s\ngot:  %s", tt.input, tt.want, got)
			}
		})
	}
}

// Embedded-NUL rejection contract: any decoded string (key or value)
// containing rune 0 must be rejected; the six-character escape-as-text
// sequence produced by a doubled backslash in source is NOT a NUL and
// must pass.
func TestCanonicalJSON_EmbeddedNULRejection(t *testing.T) {
	rejects := []struct {
		name string
		val  interface{}
	}{
		{"value", map[string]interface{}{"x": "a\x00b"}},
		{"key", map[string]interface{}{"a\x00b": "x"}},
		{"nested_value", map[string]interface{}{"o": map[string]interface{}{"k": "\x00"}}},
		{"array_element", []interface{}{"ok", "bad\x00"}},
		{"bare_string", "\x00"},
	}
	for _, tt := range rejects {
		t.Run("reject_"+tt.name, func(t *testing.T) {
			if _, err := CanonicalizeJSONChecked(tt.val); err != ErrEmbeddedNUL {
				t.Errorf("want ErrEmbeddedNUL, got %v", err)
			}
		})
	}

	// Decoded from source `{"x":"a\\u0000b"}` — the string holds the six
	// characters of the escape sequence as text, not rune 0: allowed.
	allowStr := `a\u0000b`
	got, err := CanonicalizeJSONChecked(map[string]interface{}{"x": allowStr})
	if err != nil {
		t.Fatalf("escape-as-text must be allowed, got error: %v", err)
	}
	want := `{"x":"a\\u0000b"}`
	if got != want {
		t.Errorf("escape-as-text canonical form\nwant: %s\ngot:  %s", want, got)
	}
}

func TestCanonicalJSON_EmptyObject(t *testing.T) {
	got := CanonicalizeJSON(map[string]interface{}{})
	if got != "{}" {
		t.Fatalf("empty object\nwant: {}\ngot:  %s", got)
	}
}
