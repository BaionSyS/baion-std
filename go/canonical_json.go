// BAION canonical JSON for Go — public standalone library.
// Canonical form: UTF-8, lexicographically sorted keys, minimal escaping,
// RFC 8785-style number formatting.
//
// CROSS-LINEAGE CONTRACT: output must be byte-identical across every
// language implementation of this library — the SHA-256 of the canonical
// bytes is used as a content key, so any divergence breaks key parity.
package baionstd

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
)

// CanonicalizeJSON converts any JSON-compatible value to canonical JSON string.
func CanonicalizeJSON(v interface{}) string {
	var b strings.Builder
	canonicalizeValue(&b, v)
	return b.String()
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
		b.WriteString(string(val))
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
	return strconv.FormatFloat(v, 'f', -1, 64)
}
