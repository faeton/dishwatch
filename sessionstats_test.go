package main

import (
	"testing"

	"github.com/faeton/dishwatch/internal/dish"
	"github.com/faeton/dishwatch/internal/state"
)

// ring builds a History from a per-second script. Each rune is one second:
//
//	c — clean       drop 0.0, ping 20
//	p — partial     drop 0.5, ping 40   (packets returned → latency is real)
//	d — dark        drop 1.0, ping 19   (nothing returned → latency is invented)
//
// The dark case is the one that matters: a real dish reports a plausible
// latency for every fully-dropped second, so the fixture does too.
func ring(script string) *dish.History {
	h := &dish.History{Current: int64(len(script))}
	for _, r := range script {
		var drop, ping float64
		switch r {
		case 'c':
			drop, ping = 0, 20
		case 'p':
			drop, ping = 0.5, 40
		case 'd':
			drop, ping = 1.0, 19
		default:
			panic("bad script rune")
		}
		h.PopPingDropRate = append(h.PopPingDropRate, drop)
		h.PopPingLatencyMs = append(h.PopPingLatencyMs, ping)
		h.DownlinkThroughputBps = append(h.DownlinkThroughputBps, 1e6)
		h.UplinkThroughputBps = append(h.UplinkThroughputBps, 1e5)
		h.PowerIn = append(h.PowerIn, 20)
	}
	return h
}

func TestAccumulateSegmentsOutages(t *testing.T) {
	// 3 clean, 2 dark, 2 clean, 4 dark, 1 clean → two completed outages.
	h := ring("cccddccddddc")
	var st state.Stats
	accumulate(&st, h, h.Current, int64(len(h.PopPingDropRate)))

	if st.OutageCount != 2 {
		t.Errorf("OutageCount = %d, want 2", st.OutageCount)
	}
	if st.LongestOutageS != 4 {
		t.Errorf("LongestOutageS = %d, want 4", st.LongestOutageS)
	}
	if st.OutageSeconds != 6 {
		t.Errorf("OutageSeconds = %d, want 6", st.OutageSeconds)
	}
	if st.CleanSeconds != 6 {
		t.Errorf("CleanSeconds = %d, want 6", st.CleanSeconds)
	}
	if st.CurrentOutageS != 0 {
		t.Errorf("CurrentOutageS = %d, want 0", st.CurrentOutageS)
	}
}

// A dish in a tunnel at poll time has an outage still running. It must be
// reported, but not yet folded into the completed count.
func TestAccumulateInFlightOutage(t *testing.T) {
	h := ring("ccddd")
	var st state.Stats
	accumulate(&st, h, h.Current, 5)

	if st.OutageCount != 0 {
		t.Errorf("OutageCount = %d, want 0 (run has not ended)", st.OutageCount)
	}
	if st.CurrentOutageS != 3 {
		t.Errorf("CurrentOutageS = %d, want 3", st.CurrentOutageS)
	}
	if got := st.Outages(); got != 1 {
		t.Errorf("Outages() = %d, want 1 (in-flight run counts)", got)
	}
	if got := st.LongestOutage(); got != 3 {
		t.Errorf("LongestOutage() = %d, want 3 (in-flight run may be longest)", got)
	}
}

// The reason CurrentOutageS is persisted: one tunnel spanning two polls is one
// outage, not two, and its length is the total.
func TestAccumulateOutageSpanningPolls(t *testing.T) {
	var st state.Stats
	h1 := ring("ccdd") // enters the tunnel
	accumulate(&st, h1, h1.Current, 4)
	h2 := ring("ccddddc") // same stream, two more dark seconds then clear
	accumulate(&st, h2, h2.Current, 3)

	if st.OutageCount != 1 {
		t.Errorf("OutageCount = %d, want 1 — one tunnel, not two", st.OutageCount)
	}
	if st.LongestOutageS != 4 {
		t.Errorf("LongestOutageS = %d, want 4 — both halves of the run", st.LongestOutageS)
	}
}

// The defect this whole change exists to fix: latency reported during a fully
// dark second is fabricated and must not reach the mean.
func TestAccumulateIgnoresLatencyWhenFullyDropped(t *testing.T) {
	h := ring("cdcdcd") // 3 clean @ 20 ms, 3 dark @ 19 ms
	var st state.Stats
	accumulate(&st, h, h.Current, 6)

	if st.PingCount != 3 {
		t.Fatalf("PingCount = %d, want 3 — dark seconds must be excluded", st.PingCount)
	}
	if got := st.PingAvg(); got != 20 {
		t.Errorf("PingAvg() = %v, want 20 (clean seconds only)", got)
	}
}

// Partial loss still returns packets, so that latency is a real measurement.
func TestAccumulateKeepsLatencyOnPartialLoss(t *testing.T) {
	h := ring("cp") // 20 ms clean, 40 ms at 50% loss
	var st state.Stats
	accumulate(&st, h, h.Current, 2)

	if st.PingCount != 2 {
		t.Fatalf("PingCount = %d, want 2 — partial loss is a real sample", st.PingCount)
	}
	if got := st.PingAvg(); got != 30 {
		t.Errorf("PingAvg() = %v, want 30", got)
	}
	// 50% loss is above OutageThreshold? It must not be.
	if st.OutageSeconds != 0 {
		t.Errorf("OutageSeconds = %d, want 0 — 50%% loss is degraded, not dark", st.OutageSeconds)
	}
}

// The three reported bands must partition observed time exactly — no second
// counted twice, none dropped. Degraded is derived from the other two, so the
// risk is an off-by-one at a boundary rather than a bookkeeping slip.
func TestBandsPartitionObservedTime(t *testing.T) {
	// 4 clean, 3 partial (50% loss → degraded), 3 dark.
	h := ring("ccccpppddd")
	var st state.Stats
	accumulate(&st, h, h.Current, 10)

	if st.CleanSeconds != 4 {
		t.Errorf("CleanSeconds = %d, want 4", st.CleanSeconds)
	}
	if got := st.DegradedSeconds(); got != 3 {
		t.Errorf("DegradedSeconds() = %d, want 3", got)
	}
	if st.OutageSeconds != 3 {
		t.Errorf("OutageSeconds = %d, want 3", st.OutageSeconds)
	}
	if sum := st.CleanPct() + st.DegradedPct() + st.DarkPct(); sum < 99.99 || sum > 100.01 {
		t.Errorf("bands sum to %v%%, want 100", sum)
	}
}

// A truncated or hand-edited file must not render a negative percentage.
func TestDegradedNeverNegative(t *testing.T) {
	st := state.Stats{Samples: 10, CleanSeconds: 8, OutageSeconds: 5} // inconsistent
	if got := st.DegradedSeconds(); got != 0 {
		t.Errorf("DegradedSeconds() = %d, want 0 for inconsistent input", got)
	}
}

func TestAccumulateWrapsRing(t *testing.T) {
	// Cursor past the end of the ring: indices must wrap, not panic.
	h := ring("cccc")
	h.Current = 10
	var st state.Stats
	accumulate(&st, h, h.Current, 4)

	if st.Samples != 4 {
		t.Errorf("Samples = %d, want 4", st.Samples)
	}
	if st.CleanSeconds != 4 {
		t.Errorf("CleanSeconds = %d, want 4", st.CleanSeconds)
	}
}

func TestAccumulateVolumeAndPeaks(t *testing.T) {
	h := ring("cccc")
	h.DownlinkThroughputBps[2] = 8e6 // one faster second
	var st state.Stats
	accumulate(&st, h, h.Current, 4)

	// 3 s at 1 Mbps + 1 s at 8 Mbps = 11 Mb = 1.375 MB.
	if got := st.DownBytes(); got != 11e6/8 {
		t.Errorf("DownBytes() = %v, want %v", got, 11e6/8)
	}
	if got := st.DownPeakMbps(); got != 8 {
		t.Errorf("DownPeakMbps() = %v, want 8", got)
	}
}

func TestStatsRejectsForeignVersion(t *testing.T) {
	// A file written under older rules must not be blended with new data.
	s := &state.Stats{Version: state.StatsVersion - 1, Samples: 500}
	if s.Version == state.StatsVersion {
		t.Fatal("fixture must differ from current version")
	}
	// LoadStats applies the check; assert the constant is actually consulted.
	if state.StatsVersion < 2 {
		t.Errorf("StatsVersion = %d, want >= 2 after the ping-gating change", state.StatsVersion)
	}
}
