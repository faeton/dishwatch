//go:build !unix

package state

import "os"

// No advisory-lock implementation on this platform yet. Callers degrade to the
// previous behaviour — atomic writes without an exclusive transaction — rather
// than failing. Windows would use LockFileEx if we ever ship there; see
// docs/roadmap.md.

type lockMode int

const (
	lockExclusive lockMode = iota
	lockShared
)

func lockFile(f *os.File, mode lockMode) error { return nil }

func unlockFile(f *os.File) error { return nil }
