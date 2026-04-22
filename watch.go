package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"golang.org/x/term"

	"github.com/faeton/dishwatch/internal/ui"
)

const (
	spinnerFPS = 5                      // ticks per second while waiting
	spinGlyphs = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
)

// runWatch renders `dash` every `every` seconds. Keys: q quits, r or space
// refreshes immediately.
func runWatch(ctx context.Context, every int) error {
	if every < 1 {
		every = 1
	}

	// Alt screen + hide cursor. The restore function is set up first so any
	// failure below still returns the terminal to a usable state.
	fmt.Print("\x1b[?1049h\x1b[?25l")

	fd := int(os.Stdin.Fd())
	var oldState *term.State
	if term.IsTerminal(fd) {
		st, err := term.MakeRaw(fd)
		if err == nil {
			oldState = st
		}
	}
	restore := func() {
		if oldState != nil {
			_ = term.Restore(fd, oldState)
		}
		fmt.Print("\x1b[?25h\x1b[?1049l")
	}
	defer restore()

	// Handle Ctrl-C even in raw mode (where the tty won't generate SIGINT).
	// We install a handler so `kill -INT` from another shell still cleans up.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(sigCh)

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	// Keypress reader — single bytes, non-blocking via the raw tty.
	keyCh := make(chan byte, 8)
	go func() {
		buf := make([]byte, 1)
		for {
			n, err := os.Stdin.Read(buf)
			if err != nil || n == 0 {
				return
			}
			select {
			case keyCh <- buf[0]:
			case <-ctx.Done():
				return
			}
		}
	}()

	c, dialErr := dialDish(ctx)
	if c != nil {
		defer c.Close()
	}

	glyphs := []rune(spinGlyphs)
	pi := 0

	for {
		// ---- Phase A: fetch + render (spinner during dish RPCs) ----
		var buf bytes.Buffer
		doneCh := make(chan error, 1)
		go func() {
			if dialErr != nil {
				doneCh <- dialErr
				return
			}
			s, h, err := fetchDash(ctx, c)
			if err != nil {
				doneCh <- err
				return
			}
			loc, _ := c.GetLocation(ctx)
			L := ui.DetectLayout()
			renderDash(ui.EOLPadWriter{W: &buf}, s, h, loc, L, true)
			doneCh <- nil
		}()

		tick := time.NewTicker(time.Second / spinnerFPS)
	refreshLoop:
		for {
			select {
			case err := <-doneCh:
				tick.Stop()
				// Position at home, paint frame, erase any trailing rows.
				fmt.Print("\x1b[H")
				if err != nil {
					renderUnreachable(ui.EOLPadWriter{W: os.Stdout}, true, err)
					// If the dish is flaky, try reopening next tick.
					if c != nil {
						c.Close()
					}
					c = nil
					dialErr = err
					// Attempt reconnect in background so next tick has a chance.
					go func() {
						nc, nerr := dialDish(ctx)
						if nerr == nil && nc != nil {
							// Swap in on next frame
							c = nc
							dialErr = nil
						}
					}()
				} else {
					// Rebuild client lazily if it was nil
					if c == nil {
						if nc, nerr := dialDish(ctx); nerr == nil {
							c = nc
							dialErr = nil
						}
					}
					os.Stdout.Write(buf.Bytes())
					dialErr = nil
				}
				fmt.Print("\x1b[J")
				break refreshLoop

			case <-tick.C:
				fmt.Printf("\r\x1b[K  %s%c  refreshing from dishy...  q=quit%s",
					ui.Warn, glyphs[pi], ui.Rst)
				pi = (pi + 1) % len(glyphs)

			case k := <-keyCh:
				if k == 'q' || k == 'Q' || k == 3 /* Ctrl-C */ {
					cancel()
					return nil
				}
			case <-sigCh:
				cancel()
				return nil
			case <-ctx.Done():
				return nil
			}
		}

		// ---- Phase B: countdown until next refresh ----
		remaining := every
		deadline := time.Now().Add(time.Duration(every) * time.Second)
		spin := time.NewTicker(time.Second / spinnerFPS)
	countdownLoop:
		for remaining > 0 {
			select {
			case <-spin.C:
				remaining = int(time.Until(deadline).Seconds()) + 1
				if remaining < 0 {
					remaining = 0
				}
				fmt.Printf("\r\x1b[K  %s%c  next refresh in %ds · r=now  q=quit%s",
					ui.Dim, glyphs[pi], remaining, ui.Rst)
				pi = (pi + 1) % len(glyphs)
				if time.Now().After(deadline) {
					break countdownLoop
				}
			case k := <-keyCh:
				switch k {
				case 'q', 'Q', 3:
					spin.Stop()
					cancel()
					return nil
				case 'r', 'R', ' ':
					break countdownLoop
				}
			case <-sigCh:
				spin.Stop()
				cancel()
				return nil
			case <-ctx.Done():
				spin.Stop()
				return nil
			}
		}
		spin.Stop()
	}
}

