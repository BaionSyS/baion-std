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

func TestCanonicalJSON_EmptyObject(t *testing.T) {
	got := CanonicalizeJSON(map[string]interface{}{})
	if got != "{}" {
		t.Fatalf("empty object\nwant: {}\ngot:  %s", got)
	}
}
