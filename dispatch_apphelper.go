//go:build apphelper

package main

// The command table for the engine embedded in DishWatch.app.
//
// Four operations reach the dish, and none of them is a verb: the app speaks
// the line protocol in helper.go and asks for `poll`, `reboot`, `setAnchor`
// and `ping`. So this build has exactly one real command, and the CLI's
// nineteen are not compiled into the submission at all.
//
// `--version` survives because the release checks read it and because a binary
// that cannot say what it is makes a support conversation worse. `--help`
// survives to explain what someone has found, since the file lives inside an
// app bundle where a curious person will eventually run it.
//
// Anything else is refused rather than silently treated as `status`, which is
// what the shared default used to do: the CLI defaults to `status` when given
// no arguments, so a stray exec of this binary would have dialled the dish and
// printed a terminal dashboard from inside a sandboxed app bundle.

import (
	"context"
	"fmt"
	"os"
)

const defaultCommand = "help"

func dispatch(ctx context.Context, cmd string) {
	switch cmd {
	case "helper":
		if err := runHelper(ctx); err != nil {
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
	fmt.Fprintln(os.Stderr, "dishwatch-helper — the engine embedded in DishWatch.app.")
	fmt.Fprintln(os.Stderr, "It speaks a line protocol on stdin/stdout and is not useful from a terminal.")
	fmt.Fprintln(os.Stderr, "usage: dishwatch-helper helper")
}
