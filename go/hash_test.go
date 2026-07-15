package baionstd

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"
)


func TestSHA256Hex_ReferenceValue(t *testing.T) {
	input := "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
	h := sha256.Sum256([]byte(input))
	got := hex.EncodeToString(h[:])
	want := "e5855ff48799c52c9ccf80b82bab9492c347a316876dbeaafef22b0bd4fac13d"

	if got != want {
		t.Fatalf("SHA-256 hex mismatch\nwant: %s\ngot:  %s", want, got)
	}
}
