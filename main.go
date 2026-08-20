// sl — tiny Starlink status CLI (Go port of the bash script).
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/faeton/dishwatch/internal/dish"
	"github.com/faeton/dishwatch/internal/state"
)

// version is stamped by the linker: -X main.version=$(VERSION). The Makefile
// has always passed that flag, but the symbol did not exist, and -X against a
// missing symbol is silently ignored — so every build so far has been
// unversioned without saying so.
var version = "dev"

// commit is stamped the same way: -X main.commit=$(COMMIT). .goreleaser.yaml has
// been passing that flag against a symbol that did not exist — the exact trap
// documented above for `version`, still live for this one. Declared so the flag
// takes effect, and surfaced by `--version` so a stamping regression is visible
// rather than silent.
var commit = "none"

func parsePositiveInt(s string) (int, error) {
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, err
	}
	if n < 1 {
		return 0, fmt.Errorf("must be >= 1")
	}
	return n, nil
}

func main() {
	// `defaultCommand` is per-build (see the two dispatch files). Bare
	// `dishwatch` means `status`; bare `dishwatch-helper` prints what it is.
	// Sharing the CLI's default would have made a stray exec of the bundled
	// engine dial the dish and render a terminal dashboard from inside a
	// sandboxed app bundle.
	cmd := defaultCommand
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}

	// Interactive commands trap SIGINT/SIGTERM so they can restore the terminal
	// and finish a state transaction. The helper deliberately does not.
	//
	// signal.NotifyContext *replaces* the default disposition: once SIGTERM is
	// registered it no longer terminates the process, it only cancels a context
	// somebody has to be watching. runHelper spends its life blocked reading
	// stdin, where nothing observes that context — so the supervisor's
	// Process.terminate(), which is a plain SIGTERM, did nothing at all. The
	// parent waited two seconds, gave up, and started a second helper against
	// the same state files. Leaving the default in place means terminate()
	// works; stdin EOF still covers the app-crashed case.
	ctx := context.Background()
	if cmd != "helper" {
		var cancel context.CancelFunc
		ctx, cancel = signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
		defer cancel()
	}

	dispatch(ctx, cmd)
}

func die(err error) {
	if errors.Is(err, dish.ErrUnreachable) {
		dieUnreachable()
	}
	fmt.Fprintf(os.Stderr, "\x1b[38;5;174merror:\x1b[0m %v\n", err)
	os.Exit(1)
}

// dieUnreachable mirrors bash `_sl_die_unreachable`: short, friendly hint
// pointing the user at the likely cause (wrong network, dish power, etc.)
// instead of the raw "context deadline exceeded" from the gRPC stack.
func dieUnreachable() {
	addr := os.Getenv("STARLINK_DISH")
	if addr == "" {
		addr = "192.168.100.1:9200"
	}
	fmt.Fprintf(os.Stderr, "\x1b[38;5;174mdish unreachable\x1b[0m at %s\n", addr)
	fmt.Fprintln(os.Stderr, "  · not on the Starlink network? check Wi-Fi / ethernet")
	fmt.Fprintln(os.Stderr, "  · dish rebooting or powered off?")
	fmt.Fprintln(os.Stderr, "  · try: ping 192.168.100.1")
	if snap, err := state.Load(); err == nil && snap != nil && snap.TS > 0 {
		age := time.Now().Unix() - snap.TS
		fmt.Fprintf(os.Stderr, "  · last seen %s ago — run \x1b[38;5;253msl dash\x1b[0m for frozen snapshot + events\n",
			state.HumanDur(age))
	}
	_ = state.MarkUnreachable(addr)
	os.Exit(1)
}

func dialDish(ctx context.Context) (*dish.Client, error) {
	return dish.New(ctx, os.Getenv("STARLINK_DISH"))
}
