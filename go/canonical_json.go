// BAION canonical JSON for Go — public standalone library.
// Canonical form: UTF-8, lexicographically sorted keys, minimal escaping,
// RFC 8785-style number formatting.
//
// CROSS-LINEAGE CONTRACT: output must be byte-identical across every
// language implementation of this library — the SHA-256 of the canonical
// bytes is used as a content key, so any divergence breaks key parity.
package baionstd

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"sort"
	"strconv"
	"strings"
)

// ErrEmbeddedNUL rejects inputs whose strings contain U+0000.
//
// CROSS-LINEAGE CONTRACT: every language implementation uniformly REJECTS
// documents with an embedded NUL in any string (key or value) — C-lineage
// implementations cannot round-trip NUL through NUL-terminated strings, so
// accepting it here would let Go produce hashes no sibling can reproduce.
var ErrEmbeddedNUL = errors.New("embedded U+0000 in string")

// ErrDuplicateKey rejects inputs containing an object with duplicate member
// names at any nesting depth.
//
// CROSS-LINEAGE CONTRACT: every language implementation uniformly REJECTS
// documents with duplicate object keys — decoders disagree on which member
// wins (first vs. last), so accepting them would let two lineages decode
// different values from the same bytes and silently break hash parity.
var ErrDuplicateKey = errors.New("duplicate object key")

// ErrUnsupportedNumber rejects inputs containing a number token outside the
// cross-lineage numeric domain: exponent spellings, integers beyond ±2^53,
// and fractions outside [1e-6, 1e21).
//
// CROSS-LINEAGE CONTRACT: every language implementation uniformly REJECTS
// these tokens — float formatters across the seven lineages diverge exactly
// there (exponent notation, sub-1e-6 / ≥1e21 magnitudes, >2^53 precision
// loss), so accepting them would let two lineages emit different canonical
// bytes for the same input. The check is LEXICAL on the raw token spelling:
// `100` is in-domain while `1e2` is rejected even though the values are equal.
var ErrUnsupportedNumber = errors.New("unsupported number outside the cross-lineage numeric domain")

// ErrLoneSurrogate rejects inputs containing an unpaired UTF-16 surrogate
// escape (\uD800–\uDFFF without its partner) inside a JSON string.
//
// CROSS-LINEAGE CONTRACT: every sibling lineage rejects lone surrogates at
// parse time; Go's decoder alone silently replaces them with U+FFFD, which
// would let Go produce a hash for input no sibling accepts. This must be
// detected on the RAW bytes — after decode the evidence is destroyed.
var ErrLoneSurrogate = errors.New("unsupported unpaired surrogate escape in string")

// CheckNoDuplicateKeys scans raw JSON input for duplicate object member names
// at any depth and returns ErrDuplicateKey if one is found.
//
// This check MUST run on the raw input bytes, not the decoded value: decoding
// into map[string]interface{} silently keeps one member and destroys the
// evidence, so CanonicalizeJSONChecked (which sees only the decoded tree)
// cannot detect duplicates. Callers that decode raw JSON for hashing MUST run
// this before (or alongside) decoding.
//
// Comparison is on DECODED key names — json.Decoder.Token returns each object
// key with escapes resolved, so `"\u0061"` and `"a"` are the same key and a
// document containing both is rejected.
func CheckNoDuplicateKeys(data []byte) error {
	dec := json.NewDecoder(bytes.NewReader(data))
	// UseNumber avoids float64 conversion errors on huge number tokens; this
	// pass only cares about object keys, never numeric values.
	dec.UseNumber()

	// One frame per open container. Inside an object, tokens alternate
	// key, value, key, value…; atKey tracks which position the next token
	// (or opening delimiter) fills.
	type frame struct {
		isObject bool
		atKey    bool
		seen     map[string]struct{}
	}
	var stack []*frame

	// completeValue flips the enclosing object frame back to key position
	// after a full value (scalar or closed container) has been consumed.
	completeValue := func() {
		if len(stack) > 0 && stack[len(stack)-1].isObject {
			stack[len(stack)-1].atKey = true
		}
	}

	for {
		tok, err := dec.Token()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			// Malformed JSON is not this check's verdict — the caller's
			// decode pass reports syntax errors with proper diagnostics.
			return nil
		}
		if d, ok := tok.(json.Delim); ok {
			switch d {
			case '{':
				stack = append(stack, &frame{isObject: true, atKey: true, seen: make(map[string]struct{})})
			case '[':
				stack = append(stack, &frame{})
			case '}', ']':
				stack = stack[:len(stack)-1]
				completeValue()
			}
			continue
		}
		if len(stack) > 0 && stack[len(stack)-1].isObject && stack[len(stack)-1].atKey {
			// Token() guarantees object keys are strings with escapes decoded.
			key := tok.(string)
			top := stack[len(stack)-1]
			if _, dup := top.seen[key]; dup {
				return ErrDuplicateKey
			}
			top.seen[key] = struct{}{}
			top.atKey = false
			continue
		}
		completeValue()
	}
}

// CheckNumberDomain scans raw JSON input and returns ErrUnsupportedNumber for
// any number token outside the cross-lineage domain:
//
//   - exponent spellings (any 'e'/'E' in the token) — lexical, value-blind;
//   - integer tokens (no '.') whose magnitude exceeds 9007199254740992 (2^53);
//   - fraction tokens whose value v satisfies (v != 0 && |v| < 1e-6) || |v| >= 1e21.
//
// This check MUST run on the raw input bytes: json.Number preserves the raw
// token spelling (Decoder.Token honors UseNumber), which is the only place
// `100` and `1e2` are still distinguishable — the decoded value tree cannot
// make that distinction.
func CheckNumberDomain(data []byte) error {
	dec := json.NewDecoder(bytes.NewReader(data))
	// UseNumber makes Token() yield json.Number carrying the RAW token
	// spelling — required for the lexical exponent check.
	dec.UseNumber()
	for {
		tok, err := dec.Token()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			// Malformed JSON is not this check's verdict — the caller's
			// decode pass reports syntax errors with proper diagnostics.
			return nil
		}
		n, ok := tok.(json.Number)
		if !ok {
			continue
		}
		s := string(n)
		if strings.ContainsAny(s, "eE") {
			return ErrUnsupportedNumber
		}
		if !strings.Contains(s, ".") {
			// Digit-string comparison, not ParseInt: stays exact for tokens
			// wider than any machine integer.
			if integerExceedsSafeRange(s) {
				return ErrUnsupportedNumber
			}
			continue
		}
		// Fraction token: range-check the value. ParseFloat overflow returns
		// ±Inf with ErrRange, which the >= 1e21 branch catches, so the error
		// itself needs no separate handling.
		v, _ := strconv.ParseFloat(s, 64)
		if (v != 0 && math.Abs(v) < 1e-6) || math.Abs(v) >= 1e21 {
			return ErrUnsupportedNumber
		}
	}
}

// integerExceedsSafeRange reports whether an exponent-free integer token's
// magnitude exceeds 2^53 (9007199254740992), comparing digit strings so
// arbitrarily wide tokens are judged exactly.
func integerExceedsSafeRange(s string) bool {
	digits := strings.TrimPrefix(s, "-")
	digits = strings.TrimLeft(digits, "0")
	if digits == "" {
		return false // zero
	}
	const maxSafe = "9007199254740992" // 2^53
	if len(digits) != len(maxSafe) {
		return len(digits) > len(maxSafe)
	}
	return digits > maxSafe
}

// CheckNoLoneSurrogates scans raw JSON input for unpaired UTF-16 surrogate
// escapes and returns ErrLoneSurrogate if one is found: a \uD800–\uDBFF escape
// not immediately followed by an escaped \uDC00–\uDFFF, or a \uDC00–\uDFFF
// escape with no preceding high half.
//
// Backslash-run parity decides whether a `\u` is an active escape: an escape
// starts only on the odd trailing backslash of a run, so `\\ud800` (a literal
// backslash followed by the text "ud800") is NOT a surrogate and passes.
// Escapes only occur inside strings in well-formed JSON; a stray backslash
// elsewhere is a syntax error the decode pass rejects anyway, so scanning the
// whole input is safe.
func CheckNoLoneSurrogates(data []byte) error {
	for i := 0; i < len(data); {
		if data[i] != '\\' {
			i++
			continue
		}
		j := i
		for j < len(data) && data[j] == '\\' {
			j++
		}
		run := j - i
		i = j
		if run%2 == 0 {
			continue // backslashes pair off into literal backslashes
		}
		// The trailing odd backslash escapes data[j].
		if j >= len(data) || data[j] != 'u' {
			i = j + 1
			continue
		}
		cp, ok := hex4(data, j+1)
		if !ok {
			// Malformed \u escape — the decode pass reports it.
			i = j + 1
			continue
		}
		switch {
		case cp >= 0xD800 && cp <= 0xDBFF:
			// High surrogate: valid only when immediately followed by an
			// escaped low surrogate.
			paired := false
			if j+11 <= len(data) && data[j+5] == '\\' && data[j+6] == 'u' {
				if lo, ok2 := hex4(data, j+7); ok2 && lo >= 0xDC00 && lo <= 0xDFFF {
					paired = true
				}
			}
			if !paired {
				return ErrLoneSurrogate
			}
			i = j + 11 // consume the pair so its low half is not re-seen as lone
		case cp >= 0xDC00 && cp <= 0xDFFF:
			// Low surrogate reached without a consuming high half above.
			return ErrLoneSurrogate
		default:
			i = j + 5
		}
	}
	return nil
}

// hex4 parses four hex digits at data[pos:pos+4] as a code unit.
func hex4(data []byte, pos int) (uint32, bool) {
	if pos+4 > len(data) {
		return 0, false
	}
	v, err := strconv.ParseUint(string(data[pos:pos+4]), 16, 32)
	if err != nil {
		return 0, false
	}
	return uint32(v), true
}

// CanonicalizeJSON converts any JSON-compatible value to canonical JSON string.
func CanonicalizeJSON(v interface{}) string {
	var b strings.Builder
	canonicalizeValue(&b, v)
	return b.String()
}

// CanonicalizeJSONChecked canonicalizes v after enforcing the cross-lineage
// input contract: any string (key or value) containing U+0000 is rejected
// with ErrEmbeddedNUL. Callers that hash the result MUST use this entry
// point — CanonicalizeJSON alone would emit an escaped NUL and silently diverge
// from lineages that reject.
func CanonicalizeJSONChecked(v interface{}) (string, error) {
	if err := checkNoEmbeddedNUL(v); err != nil {
		return "", err
	}
	return CanonicalizeJSON(v), nil
}

// checkNoEmbeddedNUL walks every decoded string in the value tree.
// A literal backslash-u-0000 six-character sequence in source text decodes
// to the six characters backslash-u-0-0-0-0 — not rune 0 — and is therefore allowed;
// only an actual decoded U+0000 rune is rejected.
func checkNoEmbeddedNUL(v interface{}) error {
	switch val := v.(type) {
	case string:
		if strings.ContainsRune(val, 0) {
			return ErrEmbeddedNUL
		}
	case map[string]interface{}:
		for k, item := range val {
			if strings.ContainsRune(k, 0) {
				return ErrEmbeddedNUL
			}
			if err := checkNoEmbeddedNUL(item); err != nil {
				return err
			}
		}
	case []interface{}:
		for _, item := range val {
			if err := checkNoEmbeddedNUL(item); err != nil {
				return err
			}
		}
	}
	return nil
}

// canonicalizeValue recursively writes a JSON value in canonical form.
func canonicalizeValue(b *strings.Builder, v interface{}) {
	switch val := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		if val {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case json.Number:
		b.WriteString(formatJSONNumber(val))
	case float64:
		b.WriteString(formatFloat64(val))
	case float32:
		b.WriteString(formatFloat64(float64(val)))
	case int:
		b.WriteString(strconv.Itoa(val))
	case int8:
		b.WriteString(strconv.FormatInt(int64(val), 10))
	case int16:
		b.WriteString(strconv.FormatInt(int64(val), 10))
	case int32:
		b.WriteString(strconv.FormatInt(int64(val), 10))
	case int64:
		b.WriteString(strconv.FormatInt(val, 10))
	case uint:
		b.WriteString(strconv.FormatUint(uint64(val), 10))
	case uint8:
		b.WriteString(strconv.FormatUint(uint64(val), 10))
	case uint16:
		b.WriteString(strconv.FormatUint(uint64(val), 10))
	case uint32:
		b.WriteString(strconv.FormatUint(uint64(val), 10))
	case uint64:
		b.WriteString(strconv.FormatUint(val, 10))
	case string:
		writeJSONString(b, val)
	case map[string]interface{}:
		keys := make([]string, 0, len(val))
		for k := range val {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		b.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			writeJSONString(b, k)
			b.WriteByte(':')
			canonicalizeValue(b, val[k])
		}
		b.WriteByte('}')
	case []interface{}:
		b.WriteByte('[')
		for i, item := range val {
			if i > 0 {
				b.WriteByte(',')
			}
			canonicalizeValue(b, item)
		}
		b.WriteByte(']')
	default:
		// Fallback: marshal with encoding/json (should not happen for well-formed data)
		data, _ := json.Marshal(val)
		b.Write(data)
	}
}

// writeJSONString writes a JSON-quoted string with minimal escaping.
// Only escapes characters that JSON requires: " \ and control chars 0x00-0x1F.
// Forward slash / is NOT escaped.
func writeJSONString(b *strings.Builder, s string) {
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if c < 0x20 {
				fmt.Fprintf(b, `\u%04x`, c)
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
}

// CROSS-LINEAGE CONTRACT: integer-valued floats serialize without trailing
// decimal (RFC 8785 §3.2.2.3 / ECMA-262 §7.1.12.1). Go's strconv.FormatFloat
// with format='f' and precision=-1 returns the shortest representation that
// round-trips, which for integer-valued float64 is "1" (no ".0") — matching
// the cross-implementation canonical contract. Every language implementation
// emits 1.0 → "1", -3.0 → "-3", 1.5 → "1.5"; disagreement here breaks
// SHA-256 key parity.
func formatFloat64(v float64) string {
	if math.IsNaN(v) {
		return "null" // JSON has no NaN
	}
	if math.IsInf(v, 1) {
		return "null" // JSON has no Infinity
	}
	if math.IsInf(v, -1) {
		return "null"
	}
	// CROSS-LINEAGE CONTRACT: any zero emits exactly "0" (RFC 8785 §3.2.2.3 /
	// ES ToString). -0.0 == 0 in Go, so this also catches negative zero, which
	// FormatFloat would otherwise spell "-0" and break parity with the five
	// lineages that emit "0".
	if v == 0 {
		return "0"
	}
	return strconv.FormatFloat(v, 'f', -1, 64)
}

// CROSS-LINEAGE CONTRACT: json.Number preserves the *source spelling* of a
// number ("1.0", "1e0"), but the canonical form is decided by numeric value,
// not spelling (RFC 8785 §3.2.2.3) — every sibling lineage emits 1.0 → "1".
// Writing the raw token verbatim was the parity bug: Go alone kept "1.0".
func formatJSONNumber(n json.Number) string {
	s := string(n)
	// Pure integer tokens (no '.', 'e', 'E') bypass float64 so 64-bit
	// integers keep full precision — a float64 round-trip corrupts values
	// beyond 2^53. FormatInt/FormatUint re-emission also normalizes "-0".
	if !strings.ContainsAny(s, ".eE") {
		if i, err := n.Int64(); err == nil {
			return strconv.FormatInt(i, 10)
		}
		if u, err := strconv.ParseUint(s, 10, 64); err == nil {
			return strconv.FormatUint(u, 10)
		}
	}
	f, err := n.Float64()
	if err != nil {
		// Unparseable token: the decoder already validated JSON grammar,
		// so this is unreachable in practice; emit the source token rather
		// than invent a value.
		return s
	}
	return formatFloat64(f)
}
