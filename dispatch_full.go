//go:build !apphelper

package main

// The standalone CLI's command table.
//
// Split from `main` so the engine embedded in DishWatch.app can have a
// different one — see dispatch_apphelper.go. The app drives four operations
// over a pipe and needs none of these verbs, but they shipped inside the
// bundle anyway because the helper was the whole CLI with three features
// stubbed out. A reviewer running strings(1) on a nested Mach-O sees a
// general-purpose network tool; what they should see is the engine.
//
// Guarding the dispatch rather than each command's file is what makes this
// cheap: the render and interactive paths become unreachable, and the linker
// drops unreachable functions along with the string literals only they refer
// to. The integrators in dash.go stay reachable through helper.go's poll,
// which is correct — they are the engine.

import (
	"context"
	"fmt"
	"os"
)

const defaultCommand = "status"

func dispatch(ctx context.Context, cmd string) {
	switch cmd {
	case "status":
		if err := runStatus(ctx); err != nil {
			die(err)
		}
	case "dash", "d":
		if err := runDash(ctx); err != nil {
			die(err)
		}
	case "location", "loc":
		if err := runLocation(ctx); err != nil {
			die(err)
		}
	case "history":
		if err := runHistory(ctx); err != nil {
			die(err)
		}
	case "map":
		if err := runMap(ctx); err != nil {
			die(err)
		}
	case "reboot":
		if err := runReboot(ctx); err != nil {
			die(err)
		}
	case "raw":
		req := ""
		if len(os.Args) > 2 {
			req = os.Args[2]
		}
		if err := runRaw(ctx, req); err != nil {
			die(err)
		}
	case "speed", "speedtest":
		if err := runSpeed(ctx); err != nil {
			die(err)
		}
	case "json":
		if err := runJSON(ctx, os.Args[2:]); err != nil {
			die(err)
		}
	// Private: the engine the macOS app supervises. Not in the usage line —
	// it speaks a line protocol on stdout and is useless from a terminal.
	case "helper":
		if err := runHelper(ctx); err != nil {
			die(err)
		}
	case "pb":
		if err := runPb(ctx, os.Args[2:]); err != nil {
			die(err)
		}
	case "events", "ev":
		n := 40
		if len(os.Args) > 2 {
			if v, err := parsePositiveInt(os.Args[2]); err == nil {
				n = v
			}
		}
		if err := runEvents(ctx, n); err != nil {
			die(err)
		}
	case "watch", "w":
		every := 3
		if len(os.Args) > 2 {
			if n, err := parsePositiveInt(os.Args[2]); err == nil {
				every = n
			}
		}
		if err := runWatch(ctx, every); err != nil {
			die(err)
		}
	case "-v", "--version", "version":
		fmt.Printf("dishwatch %s (%s)\n", version, commit)
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n\n", cmd)
		usage()
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: sl [status|dash|d|watch|w [sec]|events|ev [N]|history|location|loc|map|reboot|raw '<json>'|speed|pb [pct [wh] | -]|json]")
	fmt.Fprintln(os.Stderr, "       json [--window sec] — machine-readable snapshot (what the macOS app consumes)")
	fmt.Fprintln(os.Stderr, "              --window widens the sparkline series off the dish's ring, 60–900 s")
}
