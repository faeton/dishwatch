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
	cmd := "status"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

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
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n\n", cmd)
		usage()
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: sl [status|dash|d|watch|w [sec]|events|ev [N]|history|location|loc|map|reboot|raw '<json>'|speed|pb [pct [wh] | -]]")
	fmt.Fprintln(os.Stderr, "       (more commands coming — bash `sl` still has the full set)")
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
