//go:build !unix

package state

import "os"

// No advisory-lock implementation on this platform yet. Callers degrade to the
// previous behaviour — atomic writes without an exclusive transaction — rather
// than failing. Windows would use LockFileEx if we ever ship there; see
// docs/roadmap.md.
//
// The degradation is now *observable*. It used to return nil, so every caller
// believed it held a transaction and nothing anywhere could tell the difference
// between a real lock and none — on a build that `go test` never compiled,
// because the test suite only ever ran on the host platform. CI cross-compiles
// for windows now, and Txn.Degraded lets a caller say so.

type lockMode int

const (
	lockExclusive lockMode = iota
	lockShared
)

// lockingSupported is false here and true on unix. Begin/BeginRead propagate it
// to Txn.Degraded.
const lockingSupported = false

func lockFile(f *os.File, mode lockMode) error { return nil }

func unlockFile(f *os.File) error { return nil }
