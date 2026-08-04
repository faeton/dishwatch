package state

import (
	"os"
	"path/filepath"
)

// Txn is an advisory interprocess lock over the whole cache directory.
//
// Every accumulator here is read-modify-write: load the previous snapshot,
// integrate the samples that arrived since its cursor, write the result back.
// Atomic replacement (temp + rename) makes each individual write all-or-nothing
// but does nothing to make the *sequence* exclusive — two processes can both
// load the same `lastCurrent`, both integrate the same delta, and both save,
// double-counting energy and session samples. That is reachable in normal use:
// the macOS app polls `dishwatch json` on a timer while `sl watch` may be
// running in a terminal.
//
// The lock therefore has to span load→integrate→save, not just the save. It
// also has to span *all* the accumulators a single poll touches: snapshotAndLog
// advances state.json and stats.json in turn, and a competing poll landing
// between them would leave the two cursors describing different generations.
// One lock for the whole transaction gives a single commit boundary.
//
// Deliberately not addressed: the bash `sl` writes the same files without
// taking this lock. Until it is taught to, or retired, the guarantee holds
// between Go processes only.
type Txn struct {
	f *os.File
}

// lockPath is a dedicated file rather than one of the data files, so that
// locking is independent of the temp+rename dance that replaces those inodes.
func lockPath() (string, error) {
	d, err := CacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, ".lock"), nil
}

// Begin acquires the exclusive transaction lock, blocking until it is
// available. Callers must Close the returned Txn.
func Begin() (*Txn, error) { return begin(lockExclusive) }

// BeginRead acquires a shared lock — several readers may hold it at once, but
// it excludes any writer mid-transaction. Use it when reading more than one
// file, so the results cannot straddle a commit.
func BeginRead() (*Txn, error) { return begin(lockShared) }

func begin(mode lockMode) (*Txn, error) {
	p, err := lockPath()
	if err != nil {
		return nil, err
	}
	f, err := os.OpenFile(p, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	if err := lockFile(f, mode); err != nil {
		f.Close()
		return nil, err
	}
	return &Txn{f: f}, nil
}

// Close releases the lock. Safe on a nil Txn, so callers can use the
// best-effort pattern `txn, _ := state.Begin(); defer txn.Close()` without
// having to branch on whether locking succeeded.
func (t *Txn) Close() error {
	if t == nil || t.f == nil {
		return nil
	}
	err := unlockFile(t.f)
	if cerr := t.f.Close(); err == nil {
		err = cerr
	}
	t.f = nil
	return err
}
