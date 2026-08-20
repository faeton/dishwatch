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

// EnergyWh and ObsSeconds are supposed to advance together — every branch of
// integrateEnergy that adds joules also adds seconds. They are still checked
// against each other here because this file has more than one writer: the bash
// `sl` shares the schema, and a stale build earlier on $PATH can write it too.
//
// Observed on a real machine: 251.95 Wh against 192 s, which the CLI published
// as `avg 4724.1 W` and `est 140735.3 Wh over 1d 5h` — two fabricated figures
// stated with complete confidence, from two numbers that were each individually
// well-formed.
func TestObservedAvgWRefusesAnImpossiblePair(t *testing.T) {
	bad := &Snapshot{EnergyWh: 251.95, ObsSeconds: 192, UptimeS: 107247}
	if avg, ok := bad.ObservedAvgW(); ok {
		t.Fatalf("ObservedAvgW = %.1f W, want refusal — no dish draws that", avg)
	}
	// And it must not be able to claim the total covers the boot either, since
	// that is the same ObsSeconds being trusted by a different predicate.
	if bad.ObservedCoversBoot() {
		t.Fatal("ObservedCoversBoot = true on a pair we just refused to average")
	}

	// The ordinary case still works, including right at the ceiling.
	good := &Snapshot{EnergyWh: 30, ObsSeconds: 3600, UptimeS: 3600}
	avg, ok := good.ObservedAvgW()
	if !ok || avg < 29.9 || avg > 30.1 {
		t.Fatalf("ObservedAvgW = %.2f, %v; want ~30 W, true", avg, ok)
	}
	if !good.ObservedCoversBoot() {
		t.Fatal("ObservedCoversBoot = false for a boot fully covered by samples")
	}

	atCeiling := &Snapshot{EnergyWh: MaxPlausibleW, ObsSeconds: 3600, UptimeS: 3600}
	if _, ok := atCeiling.ObservedAvgW(); !ok {
		t.Fatalf("a mean of exactly %.0f W must be allowed; the bound is a ceiling, not a limit", MaxPlausibleW)
	}
}

// The plan diffs are the only ones in DiffAndLog whose inputs are routinely
// missing — the bash fallback rebuilds state.json without them, and every
// snapshot written before they existed lacks them too. So the rule that matters
// is not "does a change get logged" but "does a *non*-change stay silent".
func TestPlanChangeAbstainsWhenEitherSideIsUnrecorded(t *testing.T) {
	for _, tc := range []struct{ name, prev, cur string }{
		{"prev unrecorded (bash wrote state.json)", "", "CONSUMER"},
		{"cur unrecorded", "CONSUMER", ""},
		{"both unrecorded", "", ""},
		{"unchanged", "CONSUMER", "CONSUMER"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			t.Setenv("XDG_CACHE_HOME", dir)
			t.Setenv("HOME", dir)
			prev := &Snapshot{TS: 100, Boots: 1, UptimeS: 100, Class: tc.prev}
			cur := &Snapshot{TS: 120, Boots: 1, UptimeS: 120, Class: tc.cur}
			if err := DiffAndLog(cur, prev); err != nil {
				t.Fatalf("DiffAndLog: %v", err)
			}
			lines, _ := TailEvents(50)
			for _, l := range lines {
				if strings.Contains(l, "PLAN") {
					t.Errorf("logged a plan change from %q→%q: %s", tc.prev, tc.cur, l)
				}
			}
		})
	}
}

// And the change that is real does land — including metered, which is the
// field the whole thing was added for. `false`→`true` is a genuine transition
// precisely because dash.go records the bool unconditionally rather than
// letting the wire's omit-when-false reach the snapshot as "".
func TestPlanChangeLogsRealTransitions(t *testing.T) {
	for _, tc := range []struct {
		name, want string
		prev, cur  Snapshot
	}{
		{"class", "CLASS CONSUMER → BUSINESS",
			Snapshot{Class: "CONSUMER"}, Snapshot{Class: "BUSINESS"}},
		{"mobility", "MOBILITY NOMADIC → MOBILE",
			Snapshot{Mobility: "NOMADIC"}, Snapshot{Mobility: "MOBILE"}},
		{"metered", "METERED false → true",
			Snapshot{Metered: "false"}, Snapshot{Metered: "true"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			t.Setenv("XDG_CACHE_HOME", dir)
			t.Setenv("HOME", dir)
			prev, cur := tc.prev, tc.cur
			prev.TS, prev.Boots, prev.UptimeS = 100, 1, 100
			cur.TS, cur.Boots, cur.UptimeS = 120, 1, 120
			if err := DiffAndLog(&cur, &prev); err != nil {
				t.Fatalf("DiffAndLog: %v", err)
			}
			lines, _ := TailEvents(50)
			found := false
			for _, l := range lines {
				if strings.Contains(l, tc.want) {
					found = true
				}
			}
			if !found {
				t.Errorf("no PLAN line matching %q in %v", tc.want, lines)
			}
		})
	}
}
