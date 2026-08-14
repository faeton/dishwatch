package state

import (
	"os"
	"path/filepath"
)

// Txn is an advisory interprocess lock over the whole cache directory.
//
// Every accumulator here is read-modify-write: load the previous snapshot,
// integrate the samples that arrived since its cursor, write the result back.
// Atomic replacement (temp + rename) makes each individual write
// all-or-nothing, but does nothing to make the *sequence* exclusive. That is
// reachable in normal use: the macOS app polls `dishwatch json` on a timer
// while `sl watch` may be running in a terminal.
//
// Be precise about what goes wrong, because the obvious guess is wrong. Two
// polls that both read cursor C do not inflate the total: each writes an
// absolute value, so the loser's contribution is dropped rather than added —
// a lost update, not a double-count. And because `energyWh` and `lastCurrent`
// live in the same file, a stale write rewinds them together, leaving a pair
// that is still self-consistent; the next poll re-integrates from the older
// cursor onto the older total and lands back in roughly the right place.
// Measured, an unlocked stalled-poll rewind cost about a second of dish time,
// not a doubling.
//
// Two things are genuinely not self-healing, and they are what this lock is
// for:
//
//  1. Cross-file skew. snapshotAndLog advances state.json and then stats.json,
//     each with its own cursor. A competing poll landing between them rewinds
//     one and not the other, so `energyWh` and `obsSeconds` end up describing
//     different windows — and the dashboard prints them on the same line
//     ("obs 21m 8s @ 22.7 W"). Nothing later reconciles that. This is why the
//     lock spans *both* accumulators rather than each one individually.
//  2. A rewind older than the ring. Self-healing depends on the skipped
//     samples still being in the dish's 15-minute buffer. Past that they are
//     gone and the undercount is permanent.
//
// So the lock has to span load→integrate→save for the whole poll, not just the
// saves. Note that the far more damaging failure in this area was never the
// missing lock at all but the non-atomic write it used to sit next to: see
// writeFileAtomic in store.go, and the same fix in the bash `sl`, which now
// takes this same lock via /usr/bin/lockf.
type Txn struct {
	f *os.File
}

// NOT REENTRANT, and the failure mode is a permanent hang rather than an error.
//
// flock arbitrates per *open file description*, so a second Begin/BeginRead
// from the same process opens a second descriptor and blocks against the first
// — forever, since nothing in this package takes a timeout. Verified on darwin.
// A blocking wait between two goroutines is correct and intended (see
// TestBeginIsExclusive); what must never happen is one call path acquiring the
// lock and then calling something that acquires it again.
//
// No current path nests: runPb → runDashSilent → setAnchor and
// helper.poll → fetchDash → buildDashboard are all sequential. It is one edit
// away, so if you add a call inside a transaction, check what it loads. A
// process-wide guard was tried and removed — it cannot tell a nested acquire
// from a legitimately concurrent one, and misfired on the exclusion test.

// Degraded reports that this Txn is not actually excluding anyone, because the
// platform has no advisory-lock implementation (see lock_other.go). Callers
// that care can warn; the point is that it is no longer indistinguishable from
// a real lock.
func (t *Txn) Degraded() bool { return t != nil && !lockingSupported }

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
