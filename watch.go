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

	"github.com/faeton/dishwatch/internal/dish"
	"github.com/faeton/dishwatch/internal/ui"
)

const (
	spinnerFPS = 5 // ticks per second while waiting
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

	// The dish client belongs to this loop and to nothing else.
	//
	// It used to be shared mutable state: a background reconnect goroutine
	// assigned to `c` and `dialErr` while the render goroutine read them, with
	// no synchronisation on either — a data race in the plain sense, and one
	// that can hand the renderer a half-assigned interface value. It also
	// leaked, since a client the reconnect installed could be overwritten by
	// the loop's own lazy dial without anyone closing it.
	//
	// Now a reconnect hands its result back over a channel and the loop does
	// every assignment itself. The channel is deliberately unbuffered: a
	// finished dial parks on the send until the loop collects it, so when the
	// loop returns instead, the goroutine's ctx.Done branch closes the client
	// rather than dropping it on the floor.
	c, dialErr := dialDish(ctx)
	defer func() {
		if c != nil {
			c.Close()
		}
	}()
	reconnCh := make(chan *dish.Client)
	reconnecting := false

	glyphs := []rune(spinGlyphs)
	pi := 0

	for {
		// Collect a reconnect that finished while we were rendering or
		// counting down. Non-blocking: a dial still in flight just waits.
		select {
		case nc := <-reconnCh:
			reconnecting = false
			if nc != nil {
				if c != nil {
					c.Close()
				}
				c, dialErr = nc, nil
			}
		default:
		}

		// ---- Phase A: fetch + render (spinner during dish RPCs) ----
		var buf bytes.Buffer
		doneCh := make(chan error, 1)
		// Snapshot both before handing them to the goroutine, so the loop can
		// reassign them below without the goroutine observing the change.
		client, clientErr := c, dialErr
		go func() {
			if clientErr != nil {
				doneCh <- clientErr
				return
			}
			// Persistence errors are deliberately not printed here: watch owns
			// the alt screen, and a stderr write in the middle of a frame
			// corrupts it. A one-shot `sl dash` reports them, and the symptom
			// is visible anyway — the Energy line stops advancing.
			s, h, _, err := fetchDashPersist(ctx, client)
			if err != nil {
				doneCh <- err
				return
			}
			loc, _ := client.GetLocation(ctx)
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
					// Attempt reconnect in background so next tick has a
					// chance. One at a time — a dish that stays down would
					// otherwise accumulate a dial goroutine per frame.
					if !reconnecting {
						reconnecting = true
						go func() {
							nc, nerr := dialDish(ctx)
							if nerr != nil {
								nc = nil
							}
							select {
							case reconnCh <- nc:
							case <-ctx.Done():
								if nc != nil {
									nc.Close()
								}
							}
						}()
					}
				} else {
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
