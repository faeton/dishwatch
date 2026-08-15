package state

import "testing"

// Stats.EnergyWh is published beside the words "exact integration", so what it
// integrates is worth pinning. PowerSum is watt-seconds over 1 Hz samples, which
// is why this is not PowerAvg × Samples: `accumulate` skips samples reporting no
// power, so PowerCount and Samples diverge on hardware without a sensor.
func TestStatsEnergyWh(t *testing.T) {
	s := &Stats{PowerSum: 3600, PowerCount: 3600}
	if got := s.EnergyWh(); got < 0.999 || got > 1.001 {
		t.Fatalf("EnergyWh = %v, want 1 Wh for 3600 watt-seconds", got)
	}

	// No sensor: nothing accumulated, so nothing to claim.
	empty := &Stats{PowerSum: 0, PowerCount: 0, Samples: 7200}
	if got := empty.EnergyWh(); got != 0 {
		t.Fatalf("EnergyWh = %v with no power samples, want 0", got)
	}

	// Half the window reported power. The energy is of the samples that did,
	// which is deliberately *not* the mean spread across every second.
	half := &Stats{PowerSum: 60 * 40, PowerCount: 60, Samples: 120}
	if got := half.EnergyWh(); got < 0.6665 || got > 0.6668 {
		t.Fatalf("EnergyWh = %v, want 40 W × 60 s", got)
	}
	if avg := half.PowerAvg(); avg != 40 {
		t.Fatalf("PowerAvg = %v, want 40 — averaged over measured samples only", avg)
	}
	if spread := half.EnergyWh() * 3600 / float64(half.Samples); spread > 25 {
		t.Logf("energy spread across all %d samples reads %.1f W, not %.1f W — "+
			"the gap the UI caption glosses over", half.Samples, spread, half.PowerAvg())
	}
}
