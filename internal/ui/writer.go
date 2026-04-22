package ui

import "io"

// EOLPadWriter wraps an io.Writer and inserts ANSI "clear to end of line"
// (\e[K) before each newline. Used in watch mode so redraws don't leave
// stale characters past the end of shorter lines.
type EOLPadWriter struct{ W io.Writer }

func (e EOLPadWriter) Write(p []byte) (int, error) {
	n := 0
	for i, b := range p {
		if b == '\n' {
			if _, err := e.W.Write([]byte("\x1b[K")); err != nil {
				return n, err
			}
			if _, err := e.W.Write(p[n : i+1]); err != nil {
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
