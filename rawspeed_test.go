//go:build !apphelper

package main

import (
	"runtime"
	"slices"
	"testing"
)

// The `-W` flag means milliseconds on macOS and seconds on Linux/BSD. A single
// hardcoded value was written for macOS, which on Linux asked ping to wait
// 1000 seconds per probe — `sl speed` against an unreachable dish looked like
// a hang rather than a one-second failure.
//
// This cannot cross-check the other platform's branch from here, so it asserts
// the invariant that actually matters on whichever platform runs it: the wait
// is expressed in that platform's own units and is bounded to roughly a second.
func TestPingArgsUsesPlatformUnits(t *testing.T) {
	args := pingArgs()

	i := slices.Index(args, "-W")
	if i < 0 || i+1 >= len(args) {
		t.Fatalf("no -W wait in ping args: %v", args)
	}
	got := args[i+1]

	want := "1" // seconds, everywhere but macOS
	if runtime.GOOS == "darwin" {
		want = "1000" // milliseconds
	}
	if got != want {
		t.Errorf("on %s the -W wait is %q, want %q — wrong unit means either an\n"+
			"instant false failure or a ~17-minute apparent hang", runtime.GOOS, got, want)
	}

	if args[len(args)-1] != "192.168.100.1" {
		t.Errorf("last arg should be the dish address, got %q", args[len(args)-1])
	}
}
