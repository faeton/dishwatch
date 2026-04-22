package main

import (
	"context"
	"fmt"
	"os"

	"github.com/faeton/dishwatch/internal/state"
)

func runEvents(_ context.Context, n int) error {
	lines, err := state.TailEvents(n)
	if err != nil {
		return err
	}
	if len(lines) == 0 {
		fmt.Fprintln(os.Stderr, "no events yet")
		return nil
	}
	for _, l := range lines {
		fmt.Println(l)
	}
	return nil
}
