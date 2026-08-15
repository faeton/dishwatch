package main

import (
	"testing"

	"github.com/faeton/dishwatch/internal/state"
)

// The sparkline window became a request parameter so the app can offer 60 s /
// 5 m / 15 m over the dish's own history ring. Two things have to hold for that
// to be honest rather than merely configurable:
//
//   - a request outside the ring's usable range is clamped, not honoured; and
//   - the reply says how many samples it actually carries, so a caller cannot
//     caption a short trace with the window it asked for.
//
// The second is the load-bearing one. A dish two minutes past a reboot answers
// a 900-sample request with 120 samples, and every caption in the app reads
// SeriesSeconds rather than its own request precisely so that case cannot
// render "Last 15 m" over two minutes of data.

func TestClampSeriesWindow(t *testing.T) {
	cases := []struct {
		name string
		in   int
		want int
	}{
		{"absent means the historical default", 0, defaultSeriesWindow},
		{"negative is not a window", -30, defaultSeriesWindow},
		{"below the floor clamps up", 10, defaultSeriesWindow},
		{"the floor itself", 60, 60},
		{"in range passes through", 300, 300},
		{"the ceiling itself", maxSeriesWindow, maxSeriesWindow},
		{"beyond the ring clamps down", 5000, maxSeriesWindow},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := clampSeriesWindow(c.in); got != c.want {
				t.Fatalf("clampSeriesWindow(%d) = %d, want %d", c.in, got, c.want)
			}
		})
	}
}

func TestBuildDashboardHonoursTheWindow(t *testing.T) {
	fresh(t)
	h := powerRingWithPings(900, 900, 20)

	for _, w := range []int{60, 300, 900} {
		d := buildDashboard(statusAt(1, 4000), h, "192.168.100.1:9200", w)
		if len(d.PingSeries) != w {
			t.Fatalf("window %d: got %d ping samples, want %d", w, len(d.PingSeries), w)
		}
		if d.SeriesSeconds != w {
			t.Fatalf("window %d: SeriesSeconds = %d, want %d", w, d.SeriesSeconds, w)
		}
		for _, name := range []struct {
			label string
			n     int
		}{
			{"down", len(d.DownSeries)},
			{"up", len(d.UpSeries)},
			{"power", len(d.PowerSeries)},
		} {
			if name.n != w {
				t.Fatalf("window %d: %s series has %d samples, want %d", w, name.label, name.n, w)
			}
		}
	}
}

// The case the whole `seriesSeconds` field exists for: ask for more than the
// dish has and the answer must describe itself, not the request.
func TestSeriesSecondsReportsWhatTheRingHeldNotWhatWasAsked(t *testing.T) {
	fresh(t)
	// The shape a real dish sends 120 s after a reboot: a **full-size** 900-slot
	// ring with only 120 samples ever written. This originally allocated a
	// 120-slot ring, which is not a shape the dish ever produces — the test
	// passed while `LastN` was returning 780 unwritten zeros as readings and
	// captioning them "Last 15m".
	h := powerRingWithPings(900, 120, 20)

	d := buildDashboard(statusAt(1, 120), h, "192.168.100.1:9200", 900)
	if d.SeriesSeconds != 120 {
		t.Fatalf("SeriesSeconds = %d, want 120 — captioning this 900 would state a measurement nobody took", d.SeriesSeconds)
	}
	if len(d.PingSeries) != 120 {
		t.Fatalf("got %d ping samples, want 120", len(d.PingSeries))
	}
}

// One caption sits over three traces, so it has to be a span all three can
// support. `LastN` clamps each ring independently, so they are only equal by
// construction on firmware that ships them equal.
func TestSeriesSecondsCoversEveryCaptionedTrace(t *testing.T) {
	if got := shortestSeries([]float64{1, 2, 3}, []float64{1, 2, 3}, []float64{1, 2}); got != 2 {
		t.Fatalf("shortestSeries = %d, want 2 — the caption must not overstate the power trace", got)
	}
	// An absent ring draws no row at all. Collapsing the figure to zero would
	// hide two good traces to describe one that isn't rendered.
	if got := shortestSeries([]float64{1, 2, 3}, nil, []float64{1, 2, 3}); got != 3 {
		t.Fatalf("shortestSeries = %d, want 3 — an empty ring must not silence the others", got)
	}
	if got := shortestSeries(nil, nil, nil); got != 0 {
		t.Fatalf("shortestSeries = %d, want 0", got)
	}
}

// …and pinned through buildDashboard, not just on the helper. `powerRingWithPings`
// allocates every ring to the same length, so every other test here would still
// pass if SeriesSeconds went back to `len(PingSeries)`.
func TestSeriesSecondsThroughBuildDashboardWithUnequalRings(t *testing.T) {
	fresh(t)

	// A firmware that reports a shallower power ring than its ping ring.
	h := powerRingWithPings(900, 900, 20)
	h.PowerIn = h.PowerIn[:300]

	d := buildDashboard(statusAt(1, 4000), h, "192.168.100.1:9200", 900)
	if len(d.PingSeries) != 900 {
		t.Fatalf("ping series = %d, want the full 900", len(d.PingSeries))
	}
	if len(d.PowerSeries) != 300 {
		t.Fatalf("power series = %d, want 300", len(d.PowerSeries))
	}
	if d.SeriesSeconds != 300 {
		t.Fatalf("SeriesSeconds = %d, want 300 — one caption sits over all three traces, so it cannot claim more than the shortest", d.SeriesSeconds)
	}

	// An absent ring draws no row at all, so it must not drag the caption to
	// zero and hide the two traces that are real.
	h2 := powerRingWithPings(900, 900, 20)
	h2.PowerIn = nil
	d2 := buildDashboard(statusAt(1, 4000), h2, "192.168.100.1:9200", 900)
	if len(d2.PowerSeries) != 0 {
		t.Fatalf("power series = %d, want none", len(d2.PowerSeries))
	}
	if d2.SeriesSeconds != 900 {
		t.Fatalf("SeriesSeconds = %d, want 900", d2.SeriesSeconds)
	}
}

// No history at all is not a zero-length measurement; it is the absence of one.
// The app keys "No history yet" off this rather than off an empty array,
// because an empty array is also what a decode failure looks like.
func TestNoHistoryLeavesSeriesSecondsZero(t *testing.T) {
	fresh(t)
	d := buildDashboard(statusAt(1, 4000), nil, "192.168.100.1:9200", 300)
	if d.SeriesSeconds != 0 {
		t.Fatalf("SeriesSeconds = %d, want 0", d.SeriesSeconds)
	}
	if len(d.PingSeries) != 0 {
		t.Fatalf("got %d ping samples with no history, want none", len(d.PingSeries))
	}
}

// The refusal has to be *persisted*, not recomputed.
//
// It was a read-time gate only, and both reviewers landed on the same failure:
// integrateEnergy keeps adding to both halves underneath it, so the implied
// average decays back through the bound and the refusal expires. Measured on
// the pair this was written for — 251.95 Wh against 192 s — at a real 30 W it
// re-crosses 200 W after 85 minutes, and the CLI resumes publishing an
// extrapolation of 6242 Wh against an actual 936 Wh.
func TestImpossiblePairIsQuarantinedNotJustRefused(t *testing.T) {
	fresh(t)

	// A ring the integrator can advance from, and the incident pair as `prev`.
	h := powerRingWithPings(900, 900, 30)
	prev := &state.Snapshot{
		Boots: 1, UptimeS: 107247, EnergyWh: 251.95,
		ObsSeconds: 192, LastCurrent: 600,
	}
	s := statusAt(1, 107247)

	_, _, _, _, obsSec := integrateEnergy(s, h, prev, 1786800000)
	if obsSec != state.ObsSecondsUnknown {
		t.Fatalf("obsSeconds = %d, want ObsSecondsUnknown — a refusal that is not written back expires as the ratio decays", obsSec)
	}

	// And it stays quarantined on the next poll rather than healing.
	next := &state.Snapshot{
		Boots: 1, UptimeS: 107547, EnergyWh: 254.45,
		ObsSeconds: obsSec, LastCurrent: 900,
	}
	h2 := powerRingWithPings(900, 1200, 30)
	_, _, _, _, obsSec2 := integrateEnergy(statusAt(1, 107547), h2, next, 1786800300)
	if obsSec2 != state.ObsSecondsUnknown {
		t.Fatalf("obsSeconds = %d after another poll, want it to stay unknown until reboot", obsSec2)
	}

	// A consistent pair is untouched.
	ok := &state.Snapshot{Boots: 1, UptimeS: 4000, EnergyWh: 30, ObsSeconds: 3600, LastCurrent: 600}
	_, _, _, _, obsSec3 := integrateEnergy(statusAt(1, 4000), h, ok, 1786800000)
	if obsSec3 <= 0 {
		t.Fatalf("obsSeconds = %d, want a real count for a 30 W pair", obsSec3)
	}
}
