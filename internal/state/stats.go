package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Stats is the long-lived observed-sample accumulator behind the dashboard's
// "Observed" line. It lives in its own file (~/.cache/sl/stats.json) rather
// than in state.json on purpose: the bash `sl` rewrites state.json wholesale
// from its own jq output (see sl:111), so any Go-only field added there is
// silently wiped the next time someone runs the bash implementation.
//
// Accumulation is driven by the same monotonic get_history cursor that
// integrateEnergy uses — each poll folds in only the samples it has not seen
// before, so the numbers cover *observed* time, never wall-clock time.
//
// The epoch is one dish boot: a reboot resets every accumulator, because the
// dish's own counters reset and averaging across the discontinuity would be a
// lie. Within that epoch, gaps (CLI not running) simply contribute no samples.
type Stats struct {
	Version     int   `json:"version"`     // bumped when field semantics change → reset
	Boots       int   `json:"boots"`       // epoch guard — reset when this changes
	LastUptimeS int64 `json:"lastUptimeS"` // detects uptime regression w/o bootcount bump
	LastCurrent int64 `json:"lastCurrent"` // monotonic get_history write cursor
	Samples     int64 `json:"samples"`     // 1 Hz samples actually integrated
	ObsStartTs  int64 `json:"obsStartTs"`  // first integration in this epoch
	LastTs      int64 `json:"lastTs"`      // most recent integration

	// Latency is counted only for seconds where at least one packet came back
	// (drop < 1.0). This matters more than it looks: the dish reports a
	// plausible latency for *every* second including ones where 100% of packets
	// dropped — measured on a mobile dish in tunnels, 231 of 231 fully-dark
	// seconds carried a nonzero value, median 19.7 ms. Those numbers are
	// fabricated, and because they look like ordinary pings nothing about the
	// resulting mean reveals that a quarter of its inputs were invented.
	PingSum   float64 `json:"pingSum"`
	PingCount int64   `json:"pingCount"`
	PingMax   float64 `json:"pingMax"`

	// Drop is a fraction 0..1. Zero is a real value (no loss), so the divisor
	// is Samples, not a separate count.
	DropSum float64 `json:"dropSum"`
	DropMax float64 `json:"dropMax"`

	// Loss on a moving dish is bimodal — clean or fully dark, with almost
	// nothing between — so a mean describes a state that never occurred. These
	// segment it into events instead. CurrentOutageS carries an in-flight
	// outage across polls so one tunnel is not counted as two.
	CleanSeconds   int64 `json:"cleanSeconds"`   // drop == 0
	OutageSeconds  int64 `json:"outageSeconds"`  // drop >= OutageThreshold
	OutageCount    int64 `json:"outageCount"`    // completed outages
	LongestOutageS int64 `json:"longestOutageS"` // completed outages only
	CurrentOutageS int64 `json:"currentOutageS"` // run in progress, 0 if none

	// Throughput sums are in bit-seconds. We deliberately never surface a mean
	// from them — an idle dish averages ~0 Mbps on a perfect link, which reads
	// as a broken dish. The sum is exposed as *volume* (bytes transferred),
	// which is honest, and the max as peak capability observed.
	DownSum float64 `json:"downSum"`
	DownMax float64 `json:"downMax"`
	UpSum   float64 `json:"upSum"`
	UpMax   float64 `json:"upMax"`

	// Power is 0 on hardware that does not report it (and briefly at boot);
	// those samples are excluded rather than dragging the mean down.
	PowerSum   float64 `json:"powerSum"`
	PowerCount int64   `json:"powerCount"`
	PowerMax   float64 `json:"powerMax"`
}

// StatsVersion is bumped whenever an accumulator changes meaning, so stale
// files are discarded rather than blended with data gathered under old rules.
const StatsVersion = 2

// OutageThreshold is the drop rate at or above which a second counts as an
// outage. Not 1.0: a second at 95% loss is unusable in practice, and treating
// it as merely "degraded" would undercount short tunnels.
//
// It is deliberately left strict rather than lowered to catch the 50–90% band.
// Any single cutoff misplaces seconds near it, so the fix is to report the
// degraded band explicitly (see DegradedPct) instead of hiding the choice
// inside a threshold nobody can see.
const OutageThreshold = 0.9

func statsPath() (string, error) {
	d, err := CacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "stats.json"), nil
}

// LoadStats reads the accumulator. Returns (nil, nil) if none exists yet.
func LoadStats() (*Stats, error) {
	p, err := statsPath()
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	if len(b) == 0 {
		return nil, nil
	}
	var s Stats
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, fmt.Errorf("parse stats: %w", err)
	}
	if s.Version != StatsVersion {
		// Written under different rules — discard rather than blend. The caller
		// treats nil as "no prior state" and bootstraps from the ring.
		return nil, nil
	}
	return &s, nil
}

// SaveStats writes the accumulator atomically (temp + rename).
func SaveStats(s *Stats) error {
	p, err := statsPath()
	if err != nil {
		return err
	}
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	return writeFileAtomic(p, b, 0o644)
}

// ----- derived values -----

// ObservedSeconds is the number of seconds actually integrated — the sample
// count, not (now - ObsStartTs). Using the sample count is what makes gaps
// genuinely excluded instead of silently inflating the denominator.
func (s *Stats) ObservedSeconds() int64 { return s.Samples }

// Coverage is the fraction of the dish's uptime this epoch actually observed,
// in 0..1. At 1.0 the CLI can honestly say "since boot"; below that it has to
// qualify the window, because the unobserved time is not represented at all.
func (s *Stats) Coverage() float64 {
	if s.LastUptimeS <= 0 || s.Samples <= 0 {
		return 0
	}
	c := float64(s.Samples) / float64(s.LastUptimeS)
	if c > 1 {
		return 1
	}
	return c
}

// Ready reports whether enough samples exist for the numbers to mean anything.
// Below this the CLI hides the line rather than showing zeros as statistics.
func (s *Stats) Ready() bool { return s != nil && s.Samples >= 120 }

func (s *Stats) PingAvg() float64 {
	if s.PingCount == 0 {
		return 0
	}
	return s.PingSum / float64(s.PingCount)
}

// DropAvgPct is the mean loss over observed time. Kept for the JSON contract,
// but note it is a poor summary of a bimodal link: 65% clean and 22% fully dark
// averages to 25%, a value not one single second actually experienced. Prefer
// CleanPct plus the outage counts below.
func (s *Stats) DropAvgPct() float64 {
	if s.Samples == 0 {
		return 0
	}
	return s.DropSum / float64(s.Samples) * 100
}

func (s *Stats) DropMaxPct() float64 { return s.DropMax * 100 }

// CleanPct is the share of observed seconds with no packet loss at all.
//
// Reported alongside DegradedPct and DarkPct rather than on its own: measured
// on a moving dish, the seconds that are neither clean nor dark are not "almost
// clean" — 72% of that band sat at 20–90% loss, i.e. genuinely unusable. A
// two-way clean/dark split therefore reads as if everything not clean were a
// tunnel, when a third of it is partial obstruction.
func (s *Stats) CleanPct() float64 {
	if s.Samples == 0 {
		return 0
	}
	return float64(s.CleanSeconds) / float64(s.Samples) * 100
}

// DegradedSeconds is observed time with some loss but below OutageThreshold —
// the band between "fine" and "dark". Derived rather than accumulated, so it
// cannot disagree with its two neighbours.
func (s *Stats) DegradedSeconds() int64 {
	d := s.Samples - s.CleanSeconds - s.OutageSeconds
	if d < 0 {
		return 0 // defensive: a truncated file should not print a negative
	}
	return d
}

func (s *Stats) DegradedPct() float64 {
	if s.Samples == 0 {
		return 0
	}
	return float64(s.DegradedSeconds()) / float64(s.Samples) * 100
}

// DarkPct is the share of observed seconds at or above OutageThreshold.
func (s *Stats) DarkPct() float64 {
	if s.Samples == 0 {
		return 0
	}
	return float64(s.OutageSeconds) / float64(s.Samples) * 100
}

// Outages counts completed outages plus one for a run still in progress, so a
// tunnel you are inside right now is not omitted.
func (s *Stats) Outages() int64 {
	if s.CurrentOutageS > 0 {
		return s.OutageCount + 1
	}
	return s.OutageCount
}

// LongestOutage includes an in-flight run, which may already be the longest.
func (s *Stats) LongestOutage() int64 {
	if s.CurrentOutageS > s.LongestOutageS {
		return s.CurrentOutageS
	}
	return s.LongestOutageS
}

func (s *Stats) PowerAvg() float64 {
	if s.PowerCount == 0 {
		return 0
	}
	return s.PowerSum / float64(s.PowerCount)
}

func (s *Stats) DownPeakMbps() float64 { return s.DownMax / 1e6 }
func (s *Stats) UpPeakMbps() float64   { return s.UpMax / 1e6 }

// DownBytes converts the bit-second sum to bytes transferred. Each sample is
// one second of the reported rate, so Σ(bps) = bits, /8 = bytes.
func (s *Stats) DownBytes() float64 { return s.DownSum / 8 }
func (s *Stats) UpBytes() float64   { return s.UpSum / 8 }
