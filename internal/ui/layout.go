package ui

import (
	"os"
	"strconv"

	"golang.org/x/term"
)

// Layout captures the size-dependent dimensions of the dashboard.
type Layout struct {
	Width       int  // terminal columns
	TwoColumn   bool // render body as two side-by-side columns
	LeftColW    int  // width of the left column in two-column mode
	BarW        int  // width of progress bars
	SparkW      int  // number of samples to render in sparklines
	HeaderRule  int  // dashes after section titles
}

// Breakpoints tuned to real terminals:
//   <  72  — mobile / iTerm split / tmux pane       → single column
//   72–99  — standard 80-col + a little slack        → two columns, compact
//   ≥100   — modern wide terminals                   → two columns, roomy
func DetectLayout() Layout {
	w := 100
	// COLUMNS env var wins if set — lets users force a width, and covers
	// non-TTY stdout (pipes, `sl dash | less -R`). Fall back to the terminal
	// size; if that fails too, stay at 100.
	if env := os.Getenv("COLUMNS"); env != "" {
		if n, err := strconv.Atoi(env); err == nil && n > 0 {
			w = n
		}
	} else if cols, _, err := term.GetSize(int(os.Stdout.Fd())); err == nil && cols > 0 {
		w = cols
	} else if cols, _, err := term.GetSize(int(os.Stderr.Fd())); err == nil && cols > 0 {
		// stdout piped → try stderr (often still on TTY)
		w = cols
	}
	l := Layout{Width: w}
	switch {
	case w < 72:
		l.TwoColumn = false
		l.LeftColW = w - 2
		l.BarW = clamp(w/5, 6, 14)
		l.SparkW = clamp(w-14, 20, 60)
		l.HeaderRule = clamp(w-12, 10, 60)
	case w < 100:
		l.TwoColumn = true
		l.LeftColW = w / 2
		l.BarW = 10
		l.SparkW = clamp(w-14, 40, 60)
		l.HeaderRule = clamp(w/2-12, 10, 40)
	default:
		l.TwoColumn = true
		l.LeftColW = 52
		l.BarW = 14
		l.SparkW = 60
		l.HeaderRule = 34
	}
	return l
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
