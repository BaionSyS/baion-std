// BAION canonical JSON for Go — canon hash CLI.
// Canonical JSON + SHA-256 over the canonical bytes.
//
// Reads UTF-8 JSON on stdin, canonicalizes it (keys sorted lexicographically
// at every nesting level, no whitespace, minimal escaping), and prints the
// lowercase-hex SHA-256 of the canonical bytes followed by a newline.
// Exit 0 on success; nonzero on parse error.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"

	baionstd "baion.dev/std-go"
)

func main() {
	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "baion_canon_hash: read stdin: %v\n", err)
		os.Exit(1)
	}

	// Duplicate-key detection needs the RAW bytes: decoding into
	// map[string]interface{} keeps only one member per name and destroys the
	// duplicate, so this contract check must run before the decode below.
	if err := baionstd.CheckNoDuplicateKeys(input); err != nil {
		fmt.Fprintf(os.Stderr, "baion_canon_hash: reject: duplicate object key in input (%v)\n", err)
		os.Exit(1)
	}

	// Number-domain enforcement is LEXICAL (`100` in-domain, `1e2` rejected),
	// so it too needs the raw bytes — the decoded tree loses the spelling.
	if err := baionstd.CheckNumberDomain(input); err != nil {
		fmt.Fprintf(os.Stderr, "baion_canon_hash: reject: unsupported number in input (%v)\n", err)
		os.Exit(1)
	}

	// Lone-surrogate detection needs the raw bytes as well: Go's decoder
	// silently replaces unpaired surrogates with U+FFFD, destroying the
	// evidence every sibling lineage rejects on.
	if err := baionstd.CheckNoLoneSurrogates(input); err != nil {
		fmt.Fprintf(os.Stderr, "baion_canon_hash: reject: unpaired surrogate escape in input (%v)\n", err)
		os.Exit(1)
	}

	// json.Number preserves number spelling so canonicalization — not the
	// decoder's float64 round-trip — decides the canonical numeric form.
	dec := json.NewDecoder(bytes.NewReader(input))
	dec.UseNumber()

	var v interface{}
	if err := dec.Decode(&v); err != nil {
		fmt.Fprintf(os.Stderr, "baion_canon_hash: parse error: %v\n", err)
		os.Exit(1)
	}
	// A second successful token means trailing garbage after the JSON value —
	// reject rather than silently hashing a prefix of the input.
	if _, err := dec.Token(); err != io.EOF {
		fmt.Fprintln(os.Stderr, "baion_canon_hash: parse error: trailing data after JSON value")
		os.Exit(1)
	}

	// Checked entry point: the cross-lineage contract rejects any decoded
	// string containing U+0000, so this CLI must too.
	canonical, err := baionstd.CanonicalizeJSONChecked(v)
	if err != nil {
		fmt.Fprintf(os.Stderr, "baion_canon_hash: reject: string contains embedded U+0000 (%v)\n", err)
		os.Exit(1)
	}
	sum := sha256.Sum256([]byte(canonical))
	fmt.Println(hex.EncodeToString(sum[:]))
}
