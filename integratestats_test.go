package main

import (
	"strings"
	"testing"

	"github.com/faeton/dishwatch/internal/dish"
	"github.com/faeton/dishwatch/internal/state"
)

// sessionstats_test.go covers accumulate — the per-sample rules. These cover the
// layer above it: how many samples each poll decides are new, the epoch reset,
// and what happens when the cursor outruns the ring. That arithmetic is where a
// mistake inflates or silently discards observed time, and it is shared in
// spirit with integrateEnergy (see energy_test.go).

// fullRing returns a 900-sample clean ring (15 min at 1 Hz), the real shape,
// with the write cursor placed at cur.
func fullRing(cur int64) *dish.History {
	h := ring(strings.Repeat("c", 900))
	h.Current = cur
	return h
}

func TestIntegrateStatsBootstrapsThenIncrements(t *testing.T) {
	state.SetDir(t.TempDir())
	t.Cleanup(func() { state.SetDir("") })

	// First observation with no prior samples: bootstrap from the ring, bounded
	// by uptime so a freshly-booted dish cannot claim a full ring of history.
	st := integrateStats(statusAt(1, 300), fullRing(500), 1_700_000_000)
	if st.Samples != 300 {
		t.Fatalf("bootstrap Samples = %d, want 300 (clamped by uptime)", st.Samples)
	}

	// Steady state: only the delta since the stored cursor is new.
	st = integrateStats(statusAt(1, 360), fullRing(560), 1_700_000_060)
	if st.Samples != 360 {
		t.Fatalf("incremental Samples = %d, want 360 (+60)", st.Samples)
	}
	if st.LastCurrent != 560 {
		t.Errorf("LastCurrent = %d, want 560", st.LastCurrent)
	}
}

func TestIntegrateStatsResetsOnReboot(t *testing.T) {
	state.SetDir(t.TempDir())
	t.Cleanup(func() { state.SetDir("") })

	integrateStats(statusAt(1, 800), fullRing(800), 1_700_000_000)

	// Bootcount bump: the dish's counters restarted, so blending across the
	// boundary would average two different link sessions together.
	st := integrateStats(statusAt(2, 50), fullRing(50), 1_700_000_100)
	if st.Samples != 50 {
		t.Errorf("Samples = %d, want 50 — the epoch must reset", st.Samples)
	}
	if st.Boots != 2 {
		t.Errorf("Boots = %d, want 2", st.Boots)
	}
}

func TestIntegrateStatsResetsOnUptimeRegression(t *testing.T) {
	state.SetDir(t.TempDir())
	t.Cleanup(func() { state.SetDir("") })

	integrateStats(statusAt(1, 800), fullRing(800), 1_700_000_000)

	// Uptime went backwards without a bootcount bump — some firmware does not
	// increment it. Still a reboot.
	st := integrateStats(statusAt(1, 40), fullRing(40), 1_700_000_100)
	if st.Samples != 40 {
		t.Errorf("Samples = %d, want 40 — uptime regression must reset the epoch", st.Samples)
	}
}

// Documented envelope: poll less often than the ring wraps and those samples are
// gone. They must be skipped, not estimated — observed time may not grow by time
// nobody sampled.
func TestIntegrateStatsGapWiderThanRingAddsNothing(t *testing.T) {
	state.SetDir(t.TempDir())
	t.Cleanup(func() { state.SetDir("") })

	st := integrateStats(statusAt(1, 500), fullRing(500), 1_700_000_000)
	before := st.Samples

	// Cursor jumps 5000 samples — far past the 900-sample ring.
	st = integrateStats(statusAt(1, 5500), fullRing(5500), 1_700_005_000)

	if st.Samples != before {
		t.Errorf("Samples = %d, want %d — samples past the ring are unrecoverable", st.Samples, before)
	}
	if st.LastCurrent != 5500 {
		t.Errorf("LastCurrent = %d, want 5500 — the cursor must still resync", st.LastCurrent)
	}
}

// The near half of the envelope, and intended behaviour: a gap that still fits
// inside the ring is folded in whole. Folding forward from the stored cursor is
// what lets a slow poll cadence describe the whole interval between polls
// rather than the single second we happened to ask on — the roadmap's Phase 4
// widens that cadence to 5–15 s idle to save battery, so clamping the fold
// would thin these statistics in exact proportion to how cheap polling gets.
//
// Every second counted here is a second the dish recorded and we retrieved,
// which is all the word "Observed" claims. docs/macos-ui.md used to promise
// something narrower in the footer tooltip ("Gaps while quit are excluded");
// that copy was wrong and has been corrected rather than this code.
func TestIntegrateStatsFoldsGapsInsideRing(t *testing.T) {
	state.SetDir(t.TempDir())
	t.Cleanup(func() { state.SetDir("") })

	st := integrateStats(statusAt(1, 100), fullRing(100), 1_700_000_000)
	if st.Samples != 100 {
		t.Fatalf("setup Samples = %d, want 100", st.Samples)
	}

	// The app is quit for 600 s. The dish kept sampling; we did not observe it.
	st = integrateStats(statusAt(1, 700), fullRing(700), 1_700_000_600)

	if st.Samples != 700 {
		t.Errorf("Samples = %d, want 700 — the ring still held the whole gap", st.Samples)
	}
}

// A dish answering get_status but not get_history is a transient. It must leave
// the accumulator alone rather than resetting or double-counting it.
func TestIntegrateStatsWithoutHistoryIsInert(t *testing.T) {
	state.SetDir(t.TempDir())
	t.Cleanup(func() { state.SetDir("") })

	st := integrateStats(statusAt(1, 200), fullRing(200), 1_700_000_000)
	want := st.Samples

	if got := integrateStats(statusAt(1, 210), nil, 1_700_000_010); got.Samples != want {
		t.Errorf("Samples = %d, want %d unchanged on nil history", got.Samples, want)
	}
	empty := fullRing(0) // zero cursor: the dish has reported nothing yet
	if got := integrateStats(statusAt(1, 210), empty, 1_700_000_010); got.Samples != want {
		t.Errorf("Samples = %d, want %d unchanged on zero cursor", got.Samples, want)
	}
}
