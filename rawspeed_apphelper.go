//go:build apphelper

package main

// Stubs for the capabilities the bundled helper does not carry. The dispatch in
// main.go still recognises the verbs so an accidental invocation says something
// useful rather than "unknown command"; the implementations, and the shell-outs
// and third-party HTTP client behind them, are simply not compiled in.

import "context"

func runRaw(_ context.Context, _ string) error { return errNotInHelper }

func runSpeed(_ context.Context) error { return errNotInHelper }
