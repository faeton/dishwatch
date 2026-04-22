// Package ui renders the terminal dashboard.
package ui

import (
	"fmt"
	"regexp"
	"strings"
)

// 256-color palette — mirrors the bash version so the two renderers look
// identical while both exist.
const (
	Hdr   = "\x1b[38;5;146m" // soft purple for headers
	Lbl   = "\x1b[38;5;250m" // label grey
	Val   = "\x1b[38;5;253m" // value light
	Dim   = "\x1b[38;5;244m" // dim
	OK    = "\x1b[38;5;108m" // muted green
	Warn  = "\x1b[38;5;179m" // amber
	Err   = "\x1b[38;5;174m" // muted red
	BarBG = "\x1b[38;5;236m" // bar track
	Rst   = "\x1b[0m"
)

// HR returns an n-char horizontal rule in dim grey.
func HR(n int) string {
	return Dim + strings.Repeat("─", n) + Rst
}

// Bar renders a fixed-width horizontal bar. pct is 0..100; width is the total
// cell count. colorOverride, if non-empty, replaces the automatic threshold
// coloring (green < 60 ≤ amber < 85 ≤ red).
func Bar(pct, width int, colorOverride string) string {
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	f := pct * width / 100
	if pct > 0 && f == 0 {
		f = 1 // tiny % still shows one block
	}
	if pct < 100 && f == width {
		f = width - 1 // never visually full unless exactly 100
	}
	e := width - f
	c := OK
	if pct >= 60 {
		c = Warn
	}
	if pct >= 85 {
		c = Err
	}
	if colorOverride != "" {
		c = colorOverride
	}
	return c + strings.Repeat("█", f) + BarBG + strings.Repeat("░", e) + Rst
}

// Spark renders an 8-level block sparkline. If fixedMax > 0, the scale is
// [0, fixedMax]; otherwise min/max auto-range across the input.
func Spark(vals []float64, fixedMax float64) string {
	if len(vals) == 0 {
		return ""
	}
	chars := []rune{'▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}
	mn, mx := vals[0], vals[0]
	for _, v := range vals {
		if v < mn {
			mn = v
		}
		if v > mx {
			mx = v
		}
	}
	if fixedMax > 0 {
		mn = 0
		mx = fixedMax
	}
	rng := mx - mn
	if rng <= 0 {
		rng = 1
	}
	var b strings.Builder
	for _, v := range vals {
		idx := int((v - mn) / rng * 7)
		if idx < 0 {
			idx = 0
		}
		if idx > 7 {
			idx = 7
		}
		b.WriteRune(chars[idx])
	}
	return b.String()
}

var ansiRE = regexp.MustCompile(`\x1b\[[0-9;]*m`)

// VisibleLen returns the printable-cell length of s (strips ANSI escapes).
// Not Unicode-width-aware beyond that — OK here because we only mix ASCII,
// block drawing chars, and a handful of known symbols, all single-cell.
func VisibleLen(s string) int {
	return len([]rune(ansiRE.ReplaceAllString(s, "")))
}

// Row prints left padded to `leftWidth` visible cells, then right. Used to
// render the two-column body of the dash.
func Row(left, right string, leftWidth int) string {
	pad := leftWidth - VisibleLen(left)
	if pad < 0 {
		pad = 0
	}
	return fmt.Sprintf("%s%s%s", left, strings.Repeat(" ", pad), right)
}
