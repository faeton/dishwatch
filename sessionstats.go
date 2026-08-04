package main

import (
	"github.com/faeton/dishwatch/internal/dish"
	"github.com/faeton/dishwatch/internal/state"
)

// integrateStats advances the observed-sample accumulator in stats.json from
// the get_history rings. It mirrors integrateEnergy's dedupe exactly — the
// monotonic `current` cursor tells us how many samples are new since the last
// poll — but keeps its own cursor so the two accumulators cannot desync if one
// file is written and the other is not.
//
// Correctness envelope, same as energy: as long as we poll more often than the
// ring wraps (900 samples at 1 Hz = 15 min) no samples are missed. Poll less
// often and the gap is skipped, not estimated — which is precisely why the
// dashboard says "observed" and derives duration from Samples rather than from
// wall-clock time.
func integrateStats(s *dish.Status, h *dish.History, now int64) *state.Stats {
	if h == nil || h.Current <= 0 || len(h.PopPingLatencyMs) == 0 {
		st, _ := state.LoadStats()
		return st
	}

	st, _ := state.LoadStats()
	if st == nil {
		st = &state.Stats{}
	}

	boots := int(s.DeviceInfo.Bootcount)
	uptime := s.DeviceState.UptimeS
	cur := h.Current
	ringLen := int64(len(h.PopPingLatencyMs))

	// A reboot (or an uptime regression without a bootcount bump) ends the
	// epoch: the dish's counters restarted, so averaging across the boundary
	// would blend two different link sessions.
	reboot := st.Samples == 0 || st.Boots != boots || uptime < st.LastUptimeS

	var n int64
	if reboot {
		// Bootstrap from whatever the ring still holds. Unlike the energy
		// accumulator (see docs/optimizations.md), a first observation with no
		// prior cursor takes this path too, so we never start at zero samples
		// while claiming an observation window.
		*st = state.Stats{}
		n = uptime
		if n > ringLen {
			n = ringLen
		}
		if n > cur {
			n = cur
		}
		st.ObsStartTs = now - n
	} else {
		n = cur - st.LastCurrent
		if n > ringLen {
			// Gap larger than the ring — those samples are gone for good.
			// Advance the cursor and keep the accumulators; the missing time
			// is simply not counted as observed.
			n = 0
		}
		if n < 0 {
			n = 0
		}
	}

	if st.ObsStartTs == 0 {
		st.ObsStartTs = now
	}

	if n > ringLen {
		n = ringLen
	}
	accumulate(st, h, cur, n)

	st.Version = state.StatsVersion
	st.Boots = boots
	st.LastUptimeS = uptime
	st.LastCurrent = cur
	st.LastTs = now
	_ = state.SaveStats(st)
	return st
}

// accumulate folds the n samples ending at cursor `cur` into st. It is the
// pure half of integrateStats — no I/O, no clock — so the sample-level rules
// can be tested against a synthetic ring.
//
// One indexed pass rather than a fold per ring, because the metrics are not
// independent: whether a latency sample means anything depends on that same
// second's drop rate, and outage runs have to be walked in order to be
// segmented at all.
func accumulate(st *state.Stats, h *dish.History, cur, n int64) {
	if n <= 0 {
		return
	}
	for i := cur - n; i < cur; i++ {
		drop := at(h.PopPingDropRate, i)
		ping := at(h.PopPingLatencyMs, i)
		down := at(h.DownlinkThroughputBps, i)
		up := at(h.UplinkThroughputBps, i)
		pw := at(h.PowerIn, i)

		st.DropSum += drop
		if drop > st.DropMax {
			st.DropMax = drop
		}
		if drop == 0 {
			st.CleanSeconds++
		}

		// Segment loss into events. A mean is the wrong summary when the
		// distribution has no middle — see Stats.CleanPct.
		if drop >= state.OutageThreshold {
			st.OutageSeconds++
			st.CurrentOutageS++
		} else if st.CurrentOutageS > 0 {
			st.OutageCount++
			if st.CurrentOutageS > st.LongestOutageS {
				st.LongestOutageS = st.CurrentOutageS
			}
			st.CurrentOutageS = 0
		}

		// Only trust latency when at least one packet returned. A fully dark
		// second still carries a plausible-looking number.
		if ping > 0 && drop < 1.0 {
			st.PingSum += ping
			st.PingCount++
			if ping > st.PingMax {
				st.PingMax = ping
			}
		}

		st.DownSum += down
		if down > st.DownMax {
			st.DownMax = down
		}
		st.UpSum += up
		if up > st.UpMax {
			st.UpMax = up
		}
		if pw > 0 { // hardware without a power sensor reports 0
			st.PowerSum += pw
			st.PowerCount++
			if pw > st.PowerMax {
				st.PowerMax = pw
			}
		}
	}
	st.Samples += n
}

// at reads ring position i, wrapping. Rings that came back short or empty
// (a firmware that omits a field) read as 0 rather than panicking.
func at(ring []float64, i int64) float64 {
	rl := int64(len(ring))
	if rl == 0 {
		return 0
	}
	return ring[((i%rl)+rl)%rl]
}
