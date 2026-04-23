package ui

import "io"

// EOLPadWriter wraps an io.Writer for watch-mode rendering. Before each
// newline it writes "\e[K" (clear to end of line) so shorter redraws don't
// leave ghost characters, and it translates "\n" to "\r\n" because raw-mode
// TTYs have OPOST disabled — a bare LF would move the cursor down without
// returning to column 0, making every subsequent line drift right.
type EOLPadWriter struct{ W io.Writer }

func (e EOLPadWriter) Write(p []byte) (int, error) {
	n := 0
	for i, b := range p {
		if b == '\n' {
			if _, err := e.W.Write(p[n:i]); err != nil {
				return n, err
			}
			if _, err := e.W.Write([]byte("\x1b[K\r\n")); err != nil {
				return n, err
			}
			n = i + 1
		}
	}
	if n < len(p) {
		m, err := e.W.Write(p[n:])
		n += m
		return n, err
	}
	return len(p), nil
}
