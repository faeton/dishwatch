// sl — tiny Starlink status CLI (Go port of the bash script).
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/faeton/dishwatch/internal/dish"
)

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
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n\n", cmd)
		usage()
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: sl [status]")
	fmt.Fprintln(os.Stderr, "       (more commands coming — bash `sl` still has the full set)")
}

func die(err error) {
	fmt.Fprintf(os.Stderr, "\x1b[38;5;174merror:\x1b[0m %v\n", err)
	os.Exit(1)
}

func dialDish(ctx context.Context) (*dish.Client, error) {
	return dish.New(ctx, os.Getenv("STARLINK_DISH"))
}
