package main

import (
	"math"
	"testing"

	"github.com/faeton/dishwatch/internal/dish"
	"github.com/faeton/dishwatch/internal/state"
)

// Characterization tests for integrateEnergy. The accumulator is pure given
// (status, history, previous snapshot), which is what makes it testable without
// a dish — and it is the most error-prone code in the repo, because a cursor
// mistake shows up as a plausible-looking watt-hour total rather than a crash.

// statusAt builds the only three fields integrateEnergy reads.
func statusAt(boots int64, uptimeS int64) *dish.Status {
	s := &dish.Status{}
	s.DeviceInfo.Bootcount = boots
	s.DeviceState.UptimeS = uptimeS
	return s
}

// powerRing returns a history whose powerIn ring is `watts` everywhere, so the
// expected energy for n samples is n*watts/3600 Wh.
func powerRing(size int, cur int64, watts float64) *dish.History {
	p := make([]float64, size)
	for i := range p {
		p[i] = watts
	}
	return &dish.History{Current: cur, PowerIn: p}
}

const epsilon = 1e-9

func wh(samples int64, watts float64) float64 { return float64(samples) * watts / 3600 }

func TestIntegrateEnergy(t *testing.T) {
	tests := []struct {
		name       string
		prev       *state.Snapshot
		status     *dish.Status
		hist       *dish.History
		wantWh     float64
		wantCursor int64
	}{
		{
			// No prior state at all: bootstrap from whatever the ring holds,
			// bounded by uptime so a fresh dish doesn't claim a full ring.
			name:       "first ever poll bootstraps from ring",
			prev:       nil,
			status:     statusAt(1, 500),
			hist:       powerRing(900, 500, 20),
			wantWh:     wh(500, 20),
			wantCursor: 500,
		},
		{
			// Uptime shorter than the ring clamps the bootstrap: samples older
			// than boot belong to the previous epoch.
			name:       "bootstrap clamped by uptime",
			prev:       nil,
			status:     statusAt(1, 100),
			hist:       powerRing(900, 5000, 20),
			wantWh:     wh(100, 20),
			wantCursor: 5000,
		},
		{
			// Steady state: only the samples since the stored cursor count.
			name:       "incremental delta",
			prev:       &state.Snapshot{Boots: 1, UptimeS: 1000, EnergyWh: 5, LastCurrent: 1000},
			status:     statusAt(1, 1010),
			hist:       powerRing(900, 1010, 18),
			wantWh:     5 + wh(10, 18),
			wantCursor: 1010,
		},
		{
			// Bootcount bump: the dish's counters restarted, so the previous
			// total is abandoned rather than extended.
			name:       "reboot resets and re-bootstraps",
			prev:       &state.Snapshot{Boots: 1, UptimeS: 9000, EnergyWh: 123, LastCurrent: 9000},
			status:     statusAt(2, 50),
			hist:       powerRing(900, 50, 20),
			wantWh:     wh(50, 20),
			wantCursor: 50,
		},
		{
			// Uptime going backwards without a bootcount bump is still a
			// reboot — some firmware doesn't increment the counter.
			name:       "uptime regression treated as reboot",
			prev:       &state.Snapshot{Boots: 1, UptimeS: 9000, EnergyWh: 77, LastCurrent: 9000},
			status:     statusAt(1, 30),
			hist:       powerRing(900, 30, 20),
			wantWh:     wh(30, 20),
			wantCursor: 30,
		},
		{
			// Polled less often than the ring wraps: those samples are gone.
			// Keep the running total and resync rather than guessing.
			name:       "gap larger than ring keeps total",
			prev:       &state.Snapshot{Boots: 1, UptimeS: 1000, EnergyWh: 40, LastCurrent: 1000},
			status:     statusAt(1, 3000),
			hist:       powerRing(900, 3000, 20),
			wantWh:     40,
			wantCursor: 3000,
		},
		{
			// Regression test for the bug fixed alongside these tests: a
			// same-boot snapshot with no cursor (written by the bash `sl`, or
			// by a build predating this accumulator) used to adopt the cursor
			// and integrate nothing, silently starting the total at zero
			// mid-boot. It must bootstrap like the reboot path does.
			name:       "same-boot snapshot without cursor bootstraps",
			prev:       &state.Snapshot{Boots: 1, UptimeS: 400, LastCurrent: 0},
			status:     statusAt(1, 500),
			hist:       powerRing(900, 500, 20),
			wantWh:     wh(500, 20),
			wantCursor: 500,
		},
		{
			name:       "no new samples adds nothing",
			prev:       &state.Snapshot{Boots: 1, UptimeS: 1000, EnergyWh: 12, LastCurrent: 1000},
			status:     statusAt(1, 1000),
			hist:       powerRing(900, 1000, 20),
			wantWh:     12,
			wantCursor: 1000,
		},
		{
			// A dish reporting no power draw must not invent any.
			name:       "all-zero powerIn accumulates nothing",
			prev:       &state.Snapshot{Boots: 1, UptimeS: 1000, EnergyWh: 3, LastCurrent: 1000},
			status:     statusAt(1, 1100),
			hist:       powerRing(900, 1100, 0),
			wantWh:     3,
			wantCursor: 1100,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			gotWh, gotCur, _, _, _ := integrateEnergy(tc.status, tc.hist, tc.prev, 1_700_000_000)
			if math.Abs(gotWh-tc.wantWh) > epsilon {
				t.Errorf("energyWh = %v, want %v", gotWh, tc.wantWh)
			}
			if gotCur != tc.wantCursor {
				t.Errorf("lastCurrent = %d, want %d", gotCur, tc.wantCursor)
			}
		})
	}
}

// A missing or empty history must leave the accumulator untouched rather than
// resetting it — the dish answering get_status but not get_history is a
// transient we should ride out, not a reason to lose the running total.
func TestIntegrateEnergyWithoutHistory(t *testing.T) {
	prev := &state.Snapshot{Boots: 1, UptimeS: 1000, EnergyWh: 42, LastCurrent: 1000}
	for _, tc := range []struct {
		name string
		hist *dish.History
	}{
		{"nil history", nil},
		{"empty ring", &dish.History{Current: 1010}},
		{"zero cursor", &dish.History{Current: 0, PowerIn: make([]float64, 900)}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			gotWh, gotCur, _, _, _ := integrateEnergy(statusAt(1, 1010), tc.hist, prev, 1_700_000_000)
			if math.Abs(gotWh-42) > epsilon {
				t.Errorf("energyWh = %v, want 42 (unchanged)", gotWh)
			}
			if gotCur != 1000 {
				t.Errorf("lastCurrent = %d, want 1000 (unchanged)", gotCur)
			}
		})
	}
}
