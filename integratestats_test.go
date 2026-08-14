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
	st, _ := integrateStats(statusAt(1, 300), fullRing(500), 1_700_000_000)
	if st.Samples != 300 {
		t.Fatalf("bootstrap Samples = %d, want 300 (clamped by uptime)", st.Samples)
	}

	// Steady state: only the delta since the stored cursor is new.
	st, _ = integrateStats(statusAt(1, 360), fullRing(560), 1_700_000_060)
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

	_, _ = integrateStats(statusAt(1, 800), fullRing(800), 1_700_000_000)

	// Bootcount bump: the dish's counters restarted, so blending across the
	// boundary would average two different link sessions together.
	st, _ := integrateStats(statusAt(2, 50), fullRing(50), 1_700_000_100)
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

	_, _ = integrateStats(statusAt(1, 800), fullRing(800), 1_700_000_000)

	// Uptime went backwards without a bootcount bump — some firmware does not
	// increment it. Still a reboot.
	st, _ := integrateStats(statusAt(1, 40), fullRing(40), 1_700_000_100)
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

	st, _ := integrateStats(statusAt(1, 500), fullRing(500), 1_700_000_000)
	before := st.Samples

	// Cursor jumps 5000 samples — far past the 900-sample ring.
	st, _ = integrateStats(statusAt(1, 5500), fullRing(5500), 1_700_005_000)

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

	st, _ := integrateStats(statusAt(1, 100), fullRing(100), 1_700_000_000)
	if st.Samples != 100 {
		t.Fatalf("setup Samples = %d, want 100", st.Samples)
	}

	// The app is quit for 600 s. The dish kept sampling; we did not observe it.
	st, _ = integrateStats(statusAt(1, 700), fullRing(700), 1_700_000_600)

	if st.Samples != 700 {
		t.Errorf("Samples = %d, want 700 — the ring still held the whole gap", st.Samples)
	}
}

// A gap wider than the ring must also end any outage run in progress.
//
// `CurrentOutageS` is persisted, so a run left open when we skip a gap gets
// continued by the next dark sample — welding two separate outages into one
// across a hole we never measured. That inflates the longest run by the
// unmeasured middle and reports one outage where there were two, while the
// tooltip claims gaps beyond the ring are excluded entirely.
func TestIntegrateStatsClosesOutageAcrossAGapWiderThanRing(t *testing.T) {
	state.SetDir(t.TempDir())
	t.Cleanup(func() { state.SetDir("") })

	// A ring whose last samples are dark: the session ends mid-outage.
	darkTail := ring(strings.Repeat("c", 895) + strings.Repeat("d", 5))
	darkTail.Current = 900
	st, _ := integrateStats(statusAt(1, 900), darkTail, 1_700_000_000)
	if st.CurrentOutageS != 5 {
		t.Fatalf("setup CurrentOutageS = %d, want 5 — the run must be open", st.CurrentOutageS)
	}
	if st.OutageCount != 0 {
		t.Fatalf("setup OutageCount = %d, want 0 — the run has not ended yet", st.OutageCount)
	}

	// Two hours later, far past the 900-sample ring. Nothing in between is
	// recoverable, so the run we were in ended at the last sample we saw.
	darkHead := ring(strings.Repeat("d", 3) + strings.Repeat("c", 897))
	darkHead.Current = 8100
	st, _ = integrateStats(statusAt(1, 8100), darkHead, 1_700_007_200)

	if st.OutageCount != 1 {
		t.Errorf("OutageCount = %d, want 1 — the pre-gap run must be banked", st.OutageCount)
	}
	if st.LongestOutageS != 5 {
		t.Errorf("LongestOutageS = %d, want 5 — not the gap's width", st.LongestOutageS)
	}
	if st.CurrentOutageS != 0 {
		t.Errorf("CurrentOutageS = %d, want 0 — nothing may carry across the gap", st.CurrentOutageS)
	}
}

// A dish answering get_status but not get_history is a transient. It must leave
// the accumulator alone rather than resetting or double-counting it.
func TestIntegrateStatsWithoutHistoryIsInert(t *testing.T) {
	state.SetDir(t.TempDir())
	t.Cleanup(func() { state.SetDir("") })

	st, _ := integrateStats(statusAt(1, 200), fullRing(200), 1_700_000_000)
	want := st.Samples

	if got, _ := integrateStats(statusAt(1, 210), nil, 1_700_000_010); got.Samples != want {
		t.Errorf("Samples = %d, want %d unchanged on nil history", got.Samples, want)
	}
	empty := fullRing(0) // zero cursor: the dish has reported nothing yet
	if got, _ := integrateStats(statusAt(1, 210), empty, 1_700_000_010); got.Samples != want {
		t.Errorf("Samples = %d, want %d unchanged on zero cursor", got.Samples, want)
	}
}
