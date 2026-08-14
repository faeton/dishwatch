package main

import (
	"math"
	"testing"

	"github.com/faeton/dishwatch/internal/dish"
	"github.com/faeton/dishwatch/internal/state"
)

// Tests for the layer that owns the whole poll transaction, and for the three
// arithmetic bugs the 2026-08-14 review found in the accumulators.
//
// `snapshotAndLog` had no test at all — 0% coverage on the function whose whole
// reason to exist is holding one lock across two files. Round 2 landed that fix
// and nothing pinned it.

func fresh(t *testing.T) {
	t.Helper()
	state.SetDir(t.TempDir())
	t.Cleanup(func() { state.SetDir("") })
}

// The invariant the transaction exists for: after a poll, both files describe
// the same generation. They advance under separate cursors on purpose — either
// can be written without desyncing the other within a process — so nothing but
// a test asserts that a *completed* poll leaves them agreeing.
func TestSnapshotAndLogAdvancesBothCursorsTogether(t *testing.T) {
	fresh(t)

	if err := snapshotAndLog(statusAt(1, 400), powerRingWithPings(900, 500, 20)); err != nil {
		t.Fatalf("snapshotAndLog: %v", err)
	}
	snap, err := state.Load()
	if err != nil || snap == nil {
		t.Fatalf("state.Load: %v", err)
	}
	st, err := state.LoadStats()
	if err != nil || st == nil {
		t.Fatalf("state.LoadStats: %v", err)
	}
	if snap.LastCurrent != st.LastCurrent {
		t.Errorf("cursors disagree after one poll: state.json=%d stats.json=%d",
			snap.LastCurrent, st.LastCurrent)
	}
	if snap.ObsSeconds != st.Samples {
		t.Errorf("observed windows disagree: energy=%d samples, stats=%d samples",
			snap.ObsSeconds, st.Samples)
	}

	// And again after an increment, which is the path that actually runs 99% of
	// the time.
	if err := snapshotAndLog(statusAt(1, 460), powerRingWithPings(900, 560, 20)); err != nil {
		t.Fatalf("second snapshotAndLog: %v", err)
	}
	snap, _ = state.Load()
	st, _ = state.LoadStats()
	if snap.LastCurrent != st.LastCurrent {
		t.Errorf("cursors diverged on increment: %d vs %d", snap.LastCurrent, st.LastCurrent)
	}
	if snap.ObsSeconds != st.Samples {
		t.Errorf("windows diverged on increment: %d vs %d", snap.ObsSeconds, st.Samples)
	}
}

// obsSeconds counts samples, not elapsed time. A gap wider than the ring
// advances the cursor and contributes no energy, so it must contribute no
// observed seconds either — otherwise the average is diluted by time nobody
// measured, which is exactly how a 20 W dish came to report "avg 0.4 W".
func TestEnergyObservedSecondsExcludeGapsWiderThanRing(t *testing.T) {
	fresh(t)

	_, _, _, _, obs1 := integrateEnergy(statusAt(1, 900), powerRing(900, 900, 20), nil, 1_700_000_000)
	if obs1 != 900 {
		t.Fatalf("bootstrap obsSeconds = %d, want 900", obs1)
	}
	prev := &state.Snapshot{
		Boots: 1, UptimeS: 900, EnergyWh: wh(900, 20),
		LastCurrent: 900, ObsStartTs: 1_700_000_000 - 900, ObsSeconds: 900,
	}

	// Nine hours later, having seen nothing in between.
	const gap = 9 * 3600
	energy, cur, _, _, obs := integrateEnergy(
		statusAt(1, 900+gap), powerRing(900, 900+gap, 20), prev, 1_700_000_000+gap)

	if cur != 900+gap {
		t.Errorf("cursor = %d, want %d (must resync past the gap)", cur, 900+gap)
	}
	if math.Abs(energy-wh(900, 20)) > epsilon {
		t.Errorf("energy = %v, want unchanged %v — the gap's samples are gone", energy, wh(900, 20))
	}
	if obs != 900 {
		t.Fatalf("obsSeconds = %d, want 900 — unmeasured time must not count", obs)
	}

	// The consequence, which is the whole point: the average still describes
	// the samples we hold. Dividing by wall clock gave 0.36 W here.
	snap := &state.Snapshot{EnergyWh: energy, ObsSeconds: obs, UptimeS: 900 + gap,
		ObsStartTs: 1_700_000_000 - 900}
	avg, ok := snap.ObservedAvgW()
	if !ok {
		t.Fatal("ObservedAvgW unavailable")
	}
	if math.Abs(avg-20) > 0.01 {
		t.Errorf("avgW = %.2f W, want 20 W", avg)
	}
	if snap.ObservedCoversBoot() {
		t.Error("900 observed seconds out of 33300 must not claim to cover the boot")
	}
}

// The `+=` phantom. A same-boot snapshot carrying a real total but no cursor
// used to have the ring folded in on top of it, inventing energy that was never
// drawn. The existing table test could not see it: its prev.EnergyWh is 0,
// where `+=` and `=` agree.
func TestZeroCursorWithExistingTotalDoesNotFoldTheRing(t *testing.T) {
	fresh(t)

	prev := &state.Snapshot{Boots: 1, UptimeS: 3600, EnergyWh: 14.45, LastCurrent: 0}
	energy, cur, _, _, obs := integrateEnergy(
		statusAt(1, 3600), powerRing(900, 5000, 20), prev, 1_700_000_000)

	if math.Abs(energy-14.45) > epsilon {
		t.Errorf("energy = %v, want 14.45 unchanged; folding the ring here published %v",
			energy, 14.45+wh(900, 20))
	}
	if cur != 5000 {
		t.Errorf("cursor = %d, want 5000 — it must still resync", cur)
	}
	if obs != state.ObsSecondsUnknown {
		t.Errorf("obsSeconds = %d, want ObsSecondsUnknown", obs)
	}

	// And the epoch must *stay* unknown as new samples arrive. Letting the count
	// start from zero here pairs a numerator holding 14.45 Wh of pre-migration
	// energy with a denominator of a few fresh seconds: the first poll after
	// upgrading would have reported thousands of watts, confidently.
	prev2 := &state.Snapshot{
		Boots: 1, UptimeS: 3610, EnergyWh: energy, LastCurrent: cur, ObsSeconds: obs,
	}
	energy2, _, _, _, obs2 := integrateEnergy(
		statusAt(1, 3610), powerRing(900, 5010, 20), prev2, 1_700_000_010)

	if obs2 != state.ObsSecondsUnknown {
		t.Errorf("obsSeconds = %d after a further poll, want it to stay unknown", obs2)
	}
	snap := &state.Snapshot{EnergyWh: energy2, ObsSeconds: obs2, UptimeS: 3610}
	if avg, ok := snap.ObservedAvgW(); ok {
		t.Errorf("an unknown window offered an average of %.0f W; it must offer none", avg)
	}
	if snap.ObservedCoversBoot() {
		t.Error("an unknown window cannot claim to cover the boot")
	}
}

// The same branch with nothing to protect still bootstraps, which is the
// behaviour the branch was added for.
func TestZeroCursorWithNoTotalBootstrapsFromRing(t *testing.T) {
	fresh(t)

	prev := &state.Snapshot{Boots: 1, UptimeS: 3600, EnergyWh: 0, LastCurrent: 0}
	energy, cur, _, _, obs := integrateEnergy(
		statusAt(1, 3600), powerRing(900, 5000, 20), prev, 1_700_000_000)

	if math.Abs(energy-wh(900, 20)) > epsilon {
		t.Errorf("energy = %v, want %v (full ring)", energy, wh(900, 20))
	}
	if cur != 5000 || obs != 900 {
		t.Errorf("cursor=%d obsSeconds=%d, want 5000 and 900", cur, obs)
	}
}

// A cursor that goes backwards without a reboot must resync both accumulators.
// Energy had no `delta < 0` branch, so it fell through leaving lastCurrent at
// the stale high value and froze until the dish counted all the way back past
// it — while integrateStats resynced immediately. The two files then described
// different windows and were printed on adjacent lines.
func TestCursorRewindResyncsBothAccumulators(t *testing.T) {
	fresh(t)

	prev := &state.Snapshot{
		Boots: 1, UptimeS: 6000, EnergyWh: 30, LastCurrent: 5000, ObsSeconds: 5000,
	}
	energy, cur, _, _, obs := integrateEnergy(
		statusAt(1, 6000), powerRing(900, 100, 20), prev, 1_700_000_000)

	if cur != 100 {
		t.Errorf("energy cursor = %d, want 100 — it must resync, not freeze at 5000", cur)
	}
	if math.Abs(energy-30) > epsilon {
		t.Errorf("energy = %v, want 30 unchanged across a rewind", energy)
	}
	if obs != 5000 {
		t.Errorf("obsSeconds = %d, want 5000 unchanged", obs)
	}

	// And the stats side reaches the same cursor, which is the actual invariant.
	_, _ = integrateStats(statusAt(1, 6000), fullRing(5000), 1_700_000_000)
	st, _ := integrateStats(statusAt(1, 6000), fullRing(100), 1_700_000_100)
	if st.LastCurrent != 100 {
		t.Errorf("stats cursor = %d, want 100", st.LastCurrent)
	}
}

// One second of uptime jitter used to wipe every accumulator, because the
// reboot test was a bare `uptime < prevUptime`. A real reboot drops uptime to
// roughly zero and still trips the check.
func TestSmallUptimeRegressionIsNotAReboot(t *testing.T) {
	fresh(t)

	prev := &state.Snapshot{
		Boots: 1, UptimeS: 5000, EnergyWh: 30, LastCurrent: 5000, ObsSeconds: 5000,
	}
	energy, _, _, _, obs := integrateEnergy(
		statusAt(1, 4999), powerRing(900, 5060, 20), prev, 1_700_000_000)

	if math.Abs(energy-(30+wh(60, 20))) > epsilon {
		t.Errorf("energy = %v, want the accumulator preserved and advanced", energy)
	}
	if obs != 5060 {
		t.Errorf("obsSeconds = %d, want 5060 — a 1 s wobble is not an epoch change", obs)
	}

	// A genuine reboot still resets.
	energy2, _, _, _, obs2 := integrateEnergy(
		statusAt(1, 30), powerRing(900, 30, 20), prev, 1_700_000_000)
	if math.Abs(energy2-wh(30, 20)) > epsilon {
		t.Errorf("after a real reboot energy = %v, want %v", energy2, wh(30, 20))
	}
	if obs2 != 30 {
		t.Errorf("after a real reboot obsSeconds = %d, want 30", obs2)
	}
}

// An average with no denominator must be withheld, not faked. Snapshots written
// before ObsSeconds existed are the case.
func TestObservedAvgUnavailableWithoutSampleCount(t *testing.T) {
	legacy := &state.Snapshot{EnergyWh: 14.45, UptimeS: 3600, ObsStartTs: 1, ObsSeconds: 0}
	if _, ok := legacy.ObservedAvgW(); ok {
		t.Error("a snapshot with no sample count must not yield an average")
	}
	if legacy.ObservedCoversBoot() {
		t.Error("no sample count cannot cover the boot")
	}
}

// powerRingWithPings is powerRing plus the ping/drop rings integrateStats needs,
// so a test can drive the whole transaction rather than one accumulator.
func powerRingWithPings(size int, cur int64, watts float64) *dish.History {
	h := powerRing(size, cur, watts)
	h.PopPingLatencyMs = make([]float64, size)
	h.PopPingDropRate = make([]float64, size)
	h.DownlinkThroughputBps = make([]float64, size)
	h.UplinkThroughputBps = make([]float64, size)
	for i := 0; i < size; i++ {
		h.PopPingLatencyMs[i] = 25
	}
	return h
}
