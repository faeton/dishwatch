// sl — tiny Starlink status CLI (Go port of the bash script).
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"syscall"

	"github.com/faeton/dishwatch/internal/dish"
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
	fmt.Fprintln(os.Stderr, "usage: sl [status|dash|d|watch|w [sec]|events|ev [N]]")
	fmt.Fprintln(os.Stderr, "       (more commands coming — bash `sl` still has the full set)")
}

func die(err error) {
	fmt.Fprintf(os.Stderr, "\x1b[38;5;174merror:\x1b[0m %v\n", err)
	os.Exit(1)
}

func dialDish(ctx context.Context) (*dish.Client, error) {
	return dish.New(ctx, os.Getenv("STARLINK_DISH"))
}
