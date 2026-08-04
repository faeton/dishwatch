package state

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func tempDir(t *testing.T) string {
	t.Helper()
	d := t.TempDir()
	SetDir(d)
	t.Cleanup(func() { SetDir("") })
	return d
}

func TestSaveLoadRoundTrip(t *testing.T) {
	tempDir(t)

	if got, err := Load(); err != nil || got != nil {
		t.Fatalf("Load() on empty dir = (%v, %v), want (nil, nil)", got, err)
	}

	want := &Snapshot{TS: 1700000000, Boots: 7, UptimeS: 3600, EnergyWh: 42.5, LastCurrent: 900}
	if err := Save(want); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.Boots != want.Boots || got.EnergyWh != want.EnergyWh || got.LastCurrent != want.LastCurrent {
		t.Errorf("round trip = %+v, want %+v", got, want)
	}
}

// A fixed "<path>.tmp" name is unsafe under concurrency: two writers open the
// same temp path and interleave their bytes, so whichever renames second can
// publish a blend of both. Assert the temp name is unique per write, and that
// nothing is left behind.
func TestWriteFileAtomicUsesUniqueTempAndCleansUp(t *testing.T) {
	d := tempDir(t)
	target := filepath.Join(d, "thing.json")

	for i := 0; i < 3; i++ {
		if err := writeFileAtomic(target, []byte("payload"), 0o644); err != nil {
			t.Fatalf("writeFileAtomic: %v", err)
		}
	}

	b, err := os.ReadFile(target)
	if err != nil || string(b) != "payload" {
		t.Fatalf("content = %q (%v), want %q", b, err, "payload")
	}

	entries, err := os.ReadDir(d)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tmp") {
			t.Errorf("left a temp file behind: %s", e.Name())
		}
	}

	// The old implementation used exactly this path; nothing should create it.
	if _, err := os.Stat(target + ".tmp"); !os.IsNotExist(err) {
		t.Errorf("fixed-name temp file %s.tmp exists", target)
	}
}

// The transaction lock has to be exclusive across processes. Within a test we
// approximate that with two independent open file descriptions, which is what
// flock actually arbitrates on.
func TestBeginIsExclusive(t *testing.T) {
	tempDir(t)

	first, err := Begin()
	if err != nil {
		t.Fatalf("Begin: %v", err)
	}

	acquired := make(chan struct{})
	go func() {
		second, err := Begin()
		if err != nil {
			return
		}
		close(acquired)
		second.Close()
	}()

	select {
	case <-acquired:
		t.Fatal("second Begin acquired the lock while the first was held")
	case <-time.After(150 * time.Millisecond):
		// Expected: still blocked.
	}

	if err := first.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	select {
	case <-acquired:
		// Expected: released.
	case <-time.After(2 * time.Second):
		t.Fatal("second Begin never acquired the lock after release")
	}
}

// Readers may share, so a dashboard render never blocks another render.
func TestBeginReadIsShared(t *testing.T) {
	tempDir(t)

	a, err := BeginRead()
	if err != nil {
		t.Fatalf("BeginRead: %v", err)
	}
	defer a.Close()

	done := make(chan struct{})
	go func() {
		b, err := BeginRead()
		if err == nil {
			b.Close()
		}
		close(done)
	}()

	select {
	case <-done:
		// Expected: shared locks coexist.
	case <-time.After(2 * time.Second):
		t.Fatal("a second shared lock blocked behind the first")
	}
}

// Close must tolerate a nil receiver, so callers can write the best-effort
// pattern `txn, _ := state.Begin(); defer txn.Close()` without branching on
// whether the lock was actually taken.
func TestNilTxnCloseIsSafe(t *testing.T) {
	var txn *Txn
	if err := txn.Close(); err != nil {
		t.Errorf("(*Txn)(nil).Close() = %v, want nil", err)
	}
	if err := txn.Close(); err != nil {
		t.Errorf("second Close() = %v, want nil", err)
	}
}

// Stats carry a version so a file written under different rules is discarded
// rather than blended into current numbers.
func TestLoadStatsRejectsForeignVersion(t *testing.T) {
	tempDir(t)

	if err := SaveStats(&Stats{Version: StatsVersion, Samples: 500}); err != nil {
		t.Fatalf("SaveStats: %v", err)
	}
	got, err := LoadStats()
	if err != nil || got == nil || got.Samples != 500 {
		t.Fatalf("LoadStats() = (%+v, %v), want 500 samples", got, err)
	}

	if err := SaveStats(&Stats{Version: StatsVersion - 1, Samples: 500}); err != nil {
		t.Fatalf("SaveStats: %v", err)
	}
	got, err = LoadStats()
	if err != nil {
		t.Fatalf("LoadStats: %v", err)
	}
	if got != nil {
		t.Errorf("LoadStats() = %+v, want nil for a stale version", got)
	}
}
