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

	if n > 0 {
		foldRing(h.PopPingLatencyMs, cur, n, func(v float64) {
			if v > 0 { // 0 = no measurement, not 0 ms
				st.PingSum += v
				st.PingCount++
				if v > st.PingMax {
					st.PingMax = v
				}
			}
		})
		foldRing(h.PopPingDropRate, cur, n, func(v float64) {
			st.DropSum += v
			if v > st.DropMax {
				st.DropMax = v
			}
		})
		foldRing(h.DownlinkThroughputBps, cur, n, func(v float64) {
			st.DownSum += v
			if v > st.DownMax {
				st.DownMax = v
			}
		})
		foldRing(h.UplinkThroughputBps, cur, n, func(v float64) {
			st.UpSum += v
			if v > st.UpMax {
				st.UpMax = v
			}
		})
		foldRing(h.PowerIn, cur, n, func(v float64) {
			if v > 0 { // hardware without a power sensor reports 0
				st.PowerSum += v
				st.PowerCount++
				if v > st.PowerMax {
					st.PowerMax = v
				}
			}
		})
		if n > ringLen {
			n = ringLen
		}
		st.Samples += n
	}

	st.Boots = boots
	st.LastUptimeS = uptime
	st.LastCurrent = cur
	st.LastTs = now
	_ = state.SaveStats(st)
	return st
}

// foldRing walks the last n samples ending at the write cursor `cur`, oldest
// first, calling fn for each. n is clamped to the ring length.
func foldRing(ring []float64, cur, n int64, fn func(float64)) {
	rl := int64(len(ring))
	if rl == 0 || n <= 0 {
		return
	}
	if n > rl {
		n = rl
	}
	for i := cur - n; i < cur; i++ {
		fn(ring[((i%rl)+rl)%rl])
	}
}
