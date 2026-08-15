package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"sort"
	"strconv"
	"time"

	"github.com/faeton/dishwatch/internal/dish"
	"github.com/faeton/dishwatch/internal/state"
	"github.com/faeton/dishwatch/internal/ui"
)

func runDash(ctx context.Context) error {
	c, err := dialDish(ctx)
	if err != nil {
		_ = state.MarkUnreachable(envOr("STARLINK_DISH", "192.168.100.1:9200"))
		return renderUnreachable(os.Stdout, false, err)
	}
	defer c.Close()

	s, h, persistErr, err := fetchDashPersist(ctx, c)
	if err != nil {
		_ = state.MarkUnreachable(envOr("STARLINK_DISH", "192.168.100.1:9200"))
		return renderUnreachable(os.Stdout, false, err)
	}
	// The dish answered but the accumulators did not advance, so the Energy and
	// Observed lines below are older than everything beside them. Say so rather
	// than printing them as though they were current — a full or read-only cache
	// directory is otherwise indistinguishable from a healthy poll.
	warnPersist(persistErr)
	loc, _ := c.GetLocation(ctx)
	L := ui.DetectLayout()
	renderDash(os.Stdout, s, h, loc, L, false)
	return nil
}

// warnPersist reports a failure to advance the accumulators, once, to stderr —
// so it never corrupts `sl json` or the helper's protocol stream on stdout.
func warnPersist(err error) {
	if err != nil {
		fmt.Fprintf(os.Stderr, "warning: state not saved (%v) — energy and observed figures are stale\n", err)
	}
}

// fetchDash fetches status + history in parallel. history may be nil if that
// call failed; status failure is fatal.
//
// The persistence error from snapshotAndLog is returned separately from the
// fetch error because they mean different things to a caller: the dish data is
// good either way, but the accumulators did not advance, so anything derived
// from state.json or stats.json on this tick is stale. Callers warn rather than
// fail. Discarding it — which is what this used to do — made a full or
// read-only cache directory look exactly like a healthy poll.
func fetchDash(ctx context.Context, c *dish.Client) (*dish.Status, *dish.History, error) {
	s, h, _, err := fetchDashPersist(ctx, c)
	return s, h, err
}

func fetchDashPersist(ctx context.Context, c *dish.Client) (*dish.Status, *dish.History, error, error) {
	type statusRes struct {
		s   *dish.Status
		err error
	}
	type histRes struct {
		h   *dish.History
		err error
	}
	sCh := make(chan statusRes, 1)
	hCh := make(chan histRes, 1)
	go func() { s, e := c.GetStatus(ctx); sCh <- statusRes{s, e} }()
	go func() { h, e := c.GetHistory(ctx); hCh <- histRes{h, e} }()
	sr := <-sCh
	hr := <-hCh
	if sr.err != nil {
		return nil, nil, nil, sr.err
	}
	return sr.s, hr.h, snapshotAndLog(sr.s, hr.h), nil
}

// snapshotAndLog compares the new snapshot against the persisted one, updates
// the energy accumulator from get_history.powerIn, writes transition events,
// then replaces state.json. It returns any persistence error; the dish data is
// still valid when it does, so callers render and warn rather than fail.
func snapshotAndLog(s *dish.Status, h *dish.History) error {
	// One lock for the whole poll. Both accumulators below are
	// load→integrate→save against a monotonic cursor, so the exclusion has to
	// span the sequence rather than the individual writes — and it has to span
	// *both*, or a competing poll landing between them leaves state.json and
	// stats.json describing different generations. Best-effort: if the lock
	// can't be taken we still do the work, same as before it existed.
	txn, _ := state.Begin()
	defer txn.Close()

	prev, _ := state.Load()
	now := time.Now().Unix()
	cur := &state.Snapshot{
		TS:       now,
		Boots:    int(s.DeviceInfo.Bootcount),
		UptimeS:  s.DeviceState.UptimeS,
		State:    derivedState(s),
		Disable:  s.DisablementCode,
		Alerts:   joinActiveAlerts(s.Alerts),
		ReadyAll: strconv.FormatBool(allTrue(s.ReadyStates)),
		Ping:     s.PopPingLatencyMs,
		Drop:     s.PopPingDropRate,
	}
	cur.EnergyWh, cur.LastCurrent, cur.ObsStartTs, cur.ObsStartUptime, cur.ObsSeconds =
		integrateEnergy(s, h, prev, now)
	_ = state.DiffAndLog(cur, prev)
	// Persistence failures used to be discarded outright, which made a full or
	// read-only cache directory indistinguishable from a healthy poll: energy
	// and stats freeze, the dashboard keeps rendering, and once the stall
	// outruns the ring the missing energy is gone for good. Report them so the
	// helper can put them in `resp.Error` and the CLI can warn.
	//
	// Note the failure the lock cannot help with: Save succeeding while
	// SaveStats fails desyncs the two files exactly as a race would, because
	// this is a partial failure rather than an interleaving. Returning the
	// error is what lets a caller say so.
	saveErr := state.Save(cur)
	_, statsErr := integrateStats(s, h, now)
	return errors.Join(saveErr, statsErr)
}

// integrateEnergy advances the Wh accumulator based on the powerIn ring in
// get_history.
//
//   - powerIn[i] is watts at sample i (1 Hz ring). Summing N samples yields
//     N watt-seconds = N joules; divide by 3600 for Wh.
//   - `current` is a monotonic write cursor. We dedupe by (current - lastCurrent)
//     so each call integrates only the samples it hasn't already seen.
//   - On reboot (bootcount change OR uptime went backwards), we reset and
//     bootstrap from the ring — consuming last min(uptime, ringLen) samples.
func integrateEnergy(s *dish.Status, h *dish.History, prev *state.Snapshot, now int64) (energyWh float64, lastCur, obsStartTs, obsStartUp, obsSec int64) {
	uptime := s.DeviceState.UptimeS
	boots := int(s.DeviceInfo.Bootcount)

	var prevBoots int = -1
	var prevUptime int64 = -1
	if prev != nil {
		prevBoots = prev.Boots
		prevUptime = prev.UptimeS
		energyWh = prev.EnergyWh
		lastCur = prev.LastCurrent
		obsStartTs = prev.ObsStartTs
		obsStartUp = prev.ObsStartUptime
		obsSec = prev.ObsSeconds
	}

	reboot := prev == nil || boots != prevBoots || (prevUptime >= 0 && state.IsRestart(uptime, prevUptime))

	if h != nil && len(h.PowerIn) > 0 && h.Current > 0 {
		ringLen := int64(len(h.PowerIn))
		cur := h.Current
		if reboot {
			nb := uptime
			if nb > ringLen {
				nb = ringLen
			}
			if nb > cur {
				nb = cur
			}
			var joules float64
			if nb > 0 {
				for i := cur - nb; i < cur; i++ {
					joules += h.PowerIn[((i%ringLen)+ringLen)%ringLen]
				}
			}
			energyWh = joules / 3600
			obsStartTs = now - nb
			obsStartUp = uptime - nb
			obsSec = nb
			lastCur = cur
		} else if lastCur > 0 {
			delta := cur - lastCur
			if delta > 0 && delta <= ringLen {
				var joules float64
				for i := cur - delta; i < cur; i++ {
					joules += h.PowerIn[((i%ringLen)+ringLen)%ringLen]
				}
				energyWh += joules / 3600
				// An epoch whose count is unknown stays unknown. Adding to it
				// would pair a numerator holding hours of pre-migration energy
				// with a denominator counting only the seconds since the
				// upgrade — measured at 5802 W for a 20 W dish, stated with
				// full confidence. The next reboot clears the epoch.
				if obsSec != state.ObsSecondsUnknown {
					obsSec += delta
				}
				lastCur = cur
			} else if delta > ringLen {
				// Gap bigger than the ring — samples lost, keep accumulator.
				// obsSec deliberately does not advance: those seconds happened
				// but we hold no sample for them, and counting them would make
				// the average describe energy we never measured.
				lastCur = cur
			} else if delta < 0 {
				// The cursor went backwards without a reboot — the dish's
				// history service restarted, or firmware renumbered the ring.
				// Resync and integrate nothing.
				//
				// This branch used to be absent, which was worse than it looks:
				// falling through left lastCur at the stale high value, so
				// energy froze until the dish counted all the way back past it,
				// while integrateStats resynced immediately. The two files then
				// described different windows and were printed on adjacent
				// lines. Symmetry here is the point.
				lastCur = cur
			}
		} else {
			// A same-boot snapshot exists but carries no cursor — written by
			// the bash `sl`, or by a build predating this accumulator.
			//
			// Two sub-cases, and conflating them was a bug. If no energy has
			// been recorded yet there is nothing to lose, so bootstrap from the
			// ring exactly as the reboot path does. But if a total is already
			// there, we do not know how much of the ring it already covers —
			// this branch used to fold the ring in with `+=` on top of it,
			// which invented energy: a real 14.45 Wh total plus a full 900
			// sample ring at 20 W published 19.45 Wh, a 5 Wh phantom.
			//
			// Folding is unsafe and discarding is lossy, so do neither: adopt
			// the cursor and integrate nothing. We give up at most the ring
			// (~15 min) rather than fabricate, which is the same under-claim
			// integrateStats makes for a gap wider than the ring.
			if energyWh != 0 {
				// A total we cannot account for. Adopt the cursor, fold nothing
				// (see below), and mark the observation window unknown so no
				// average is offered for this epoch. The next reboot clears it.
				obsSec = state.ObsSecondsUnknown
			} else {
				nb := uptime
				if nb > ringLen {
					nb = ringLen
				}
				if nb > cur {
					nb = cur
				}
				var joules float64
				for i := cur - nb; i < cur; i++ {
					joules += h.PowerIn[((i%ringLen)+ringLen)%ringLen]
				}
				energyWh = joules / 3600
				obsSec = nb
				if obsStartTs == 0 {
					obsStartTs = now - nb
				}
				if obsStartUp == 0 {
					obsStartUp = uptime - nb
				}
			}
			lastCur = cur
		}
	}
	if obsStartTs == 0 {
		obsStartTs = now
	}
	return
}

func derivedState(s *dish.Status) string {
	if s.DisablementCode != "" && s.DisablementCode != "OKAY" {
		return "DISABLED"
	}
	if allTrue(s.ReadyStates) {
		return "CONNECTED"
	}
	if s.State != "" {
		return s.State
	}
	return "NOT READY"
}

func renderUnreachable(w io.Writer, inWatch bool, err error) error {
	if !inWatch {
		fmt.Fprint(w, "\x1b[H\x1b[J")
	}
	fmt.Fprintln(w)
	addr := envOr("STARLINK_DISH", "192.168.100.1:9200")
	fmt.Fprintf(w, "  %sStarlink%s  %s● UNREACHABLE%s  %s%s%s\n",
		ui.Hdr, ui.Rst, ui.Err, ui.Rst, ui.Dim, addr, ui.Rst)
	fmt.Fprintf(w, "  %sapi did not answer — could be local Wi-Fi, ethernet, or the dish rebooting%s\n\n",
		ui.Dim, ui.Rst)

	if snap, _ := state.Load(); snap != nil {
		age := time.Now().Unix() - snap.TS
		fmt.Fprintf(w, "  %sLast seen%s   %s%s ago%s  %sstate=%s  disable=%s  ping=%.1fms  boots=%d  up=%ds%s\n",
			ui.Lbl, ui.Rst, ui.Val, state.HumanDur(age), ui.Rst,
			ui.Dim, snap.State, snap.Disable, snap.Ping, snap.Boots, snap.UptimeS, ui.Rst)
	}

	if lines, _ := state.TailEvents(10); len(lines) > 0 {
		fmt.Fprintf(w, "\n  %sRecent events (last %d):%s\n", ui.Hdr, len(lines), ui.Rst)
		for _, l := range lines {
			fmt.Fprintf(w, "  %s%s%s\n", ui.Dim, l, ui.Rst)
		}
	}
	fmt.Fprintf(w, "\n%s  %s · %s%s\n", ui.Dim, addr, time.Now().Format("15:04:05"), ui.Rst)
	_ = err
	return nil
}

func renderDash(w io.Writer, s *dish.Status, h *dish.History, loc *dish.Location, L ui.Layout, inWatch bool) {
	// In watch mode the caller positions the cursor at (0,0) and pads lines
	// to the right edge themselves, so we skip the clear.
	if !inWatch {
		fmt.Fprint(w, "\x1b[H\x1b[J")
	}
	fmt.Fprintln(w)

	// State machine
	state := s.State
	if state == "" {
		if allTrue(s.ReadyStates) {
			state = "CONNECTED"
		} else {
			state = "NOT READY"
		}
	}
	dotColor := ui.Warn
	if allTrue(s.ReadyStates) && s.DisablementCode == "OKAY" {
		dotColor = ui.OK
		state = "CONNECTED"
	} else if s.DisablementCode != "" && s.DisablementCode != "OKAY" {
		dotColor = ui.Err
		state = "DISABLED"
	}

	// Header
	upH := float64(s.DeviceState.UptimeS) / 3600
	fmt.Fprintf(w, "  %sStarlink%s  %s●%s %s%s  %s%s · %s · %s%s  %sup %.1fh · boots %d%s\n",
		ui.Hdr, ui.Rst, dotColor, ui.Rst, ui.Val, state,
		ui.Dim, dashIf(s.ClassOfService), dashIf(s.MobilityClass), dashIf(s.DeviceInfo.CountryCode), ui.Rst,
		ui.Dim, upH, s.DeviceInfo.Bootcount, ui.Rst)
	fmt.Fprintf(w, "  %s%s · fw %s%s\n\n",
		ui.Dim, s.DeviceInfo.HardwareVersion, s.DeviceInfo.SoftwareVersion, ui.Rst)

	// Derived values
	downMbps := s.DownlinkThroughputBps / 1e6
	upMbps := s.UplinkThroughputBps / 1e6
	dropPct := s.PopPingDropRate * 100
	obsPct := s.ObstructionStats.FractionObstructed * 100
	timeObsPct := s.ObstructionStats.TimeObstructed * 100
	dnBarPct := int(s.DownlinkThroughputBps / 2e8 * 100) // vs nominal 200 Mbps
	upBarPct := int(s.UplinkThroughputBps / 4e7 * 100)   // vs nominal 40 Mbps
	pingBarPct := int(math.Min(s.PopPingLatencyMs, 100))

	// Signal score — since dB SNR is hidden, synthesize from ping/drop/obs.
	sigScore := signalScore(s)

	pingColor := ui.OK
	if s.PopPingLatencyMs >= 60 {
		pingColor = ui.Warn
	}
	if s.PopPingLatencyMs >= 120 {
		pingColor = ui.Err
	}

	alertsColor := ui.OK
	alertsStr := joinActiveAlerts(s.Alerts)
	if alertsStr != "none" {
		alertsColor = ui.Err
	}

	sigColor := ui.Err
	if sigScore >= 50 {
		sigColor = ui.Warn
	}
	if sigScore >= 75 {
		sigColor = ui.OK
	}
	flag := "noise ✓"
	if s.IsSnrPersistentlyLow {
		flag = "low ✗"
	}
	if !s.IsSnrAboveNoiseFloor {
		flag = "weak ✗"
	}

	// Power from history ring
	var pwNow float64
	var havePwNow bool
	if h != nil {
		pwNow, havePwNow = h.Latest(h.PowerIn)
	}
	pwColor := ui.OK
	if pwNow >= 25 {
		pwColor = ui.Warn
	}
	if pwNow >= 40 {
		pwColor = ui.Err
	}

	svcStr, svcColor := serviceStatus(s.DisablementCode)

	// Build left/right column lines
	var Lcol, Rcol []string
	sec := func(icon, title string) string {
		return fmt.Sprintf("%s%s %s %s%s", ui.Hdr, icon, title, ui.HR(L.HeaderRule), ui.Rst)
	}

	Lcol = append(Lcol, sec("●", "Connection"))
	Rcol = append(Rcol, sec("↕", "Throughput"))

	Lcol = append(Lcol, fmt.Sprintf("%sState   %s %s%s%s", ui.Lbl, ui.Rst, ui.Val, state, ui.Rst))
	// DL/UL rather than Down/Up: "Up" sits two lines from an uptime figure and
	// reads as one.
	Rcol = append(Rcol, fmt.Sprintf("%sDL      %s %s  %s%.2f Mbps%s",
		ui.Lbl, ui.Rst, ui.Bar(dnBarPct, L.BarW, ""), ui.Val, downMbps, ui.Rst))

	readyShort := ui.OK + "✓ all" + ui.Rst
	if !allTrue(s.ReadyStates) {
		readyShort = ui.Err + "not ready" + ui.Rst
	}
	Lcol = append(Lcol, fmt.Sprintf("%sReady   %s %s  %s%s%s",
		ui.Lbl, ui.Rst, readyShort, ui.Dim, readyKeysCompact(s.ReadyStates), ui.Rst))
	Rcol = append(Rcol, fmt.Sprintf("%sUL      %s %s  %s%.2f Mbps%s",
		ui.Lbl, ui.Rst, ui.Bar(upBarPct, L.BarW, ""), ui.Val, upMbps, ui.Rst))

	Lcol = append(Lcol, fmt.Sprintf("%sPing    %s %s%.1f ms%s  %sdrop %.1f%%%s",
		ui.Lbl, ui.Rst, pingColor, s.PopPingLatencyMs, ui.Rst, ui.Dim, dropPct, ui.Rst))
	Rcol = append(Rcol, fmt.Sprintf("%sPing    %s %s  %svs 100ms target%s",
		ui.Lbl, ui.Rst, ui.Bar(pingBarPct, L.BarW, ""), ui.Dim, ui.Rst))

	Lcol = append(Lcol, fmt.Sprintf("%sAlerts  %s %s%s%s",
		ui.Lbl, ui.Rst, alertsColor, alertsStr, ui.Rst))
	Rcol = append(Rcol, fmt.Sprintf("%sLimits  %s %sdl=%s  ul=%s%s",
		ui.Lbl, ui.Rst, ui.Val, dashIf(s.DlBandwidthRestricted), dashIf(s.UlBandwidthRestricted), ui.Rst))

	Lcol = append(Lcol, "")
	Rcol = append(Rcol, "")

	Lcol = append(Lcol, sec("◆", "Signal"))
	Rcol = append(Rcol, sec("◎", "Aim"))

	Lcol = append(Lcol, fmt.Sprintf("%sSignal  %s %s  %s%d/100%s  %s%s%s",
		ui.Lbl, ui.Rst, ui.Bar(sigScore, L.BarW, sigColor), sigColor, sigScore, ui.Rst, ui.Dim, flag, ui.Rst))
	Rcol = append(Rcol, fmt.Sprintf("%sAzim    %s %s%.1f°%s  %swant %.0f°%s",
		ui.Lbl, ui.Rst, ui.Val, s.BoresightAzimuthDeg, ui.Rst,
		ui.Dim, s.AlignmentStats.DesiredBoresightAzimuthDeg, ui.Rst))

	Lcol = append(Lcol, fmt.Sprintf("%sObstr   %s %s  %s%.2f%%%s",
		ui.Lbl, ui.Rst, ui.Bar(int(obsPct), L.BarW, ""), ui.Val, obsPct, ui.Rst))
	Rcol = append(Rcol, fmt.Sprintf("%sElev    %s %s%.1f°%s  %swant %.0f°%s",
		ui.Lbl, ui.Rst, ui.Val, s.BoresightElevationDeg, ui.Rst,
		ui.Dim, s.AlignmentStats.DesiredBoresightElevationDeg, ui.Rst))

	Lcol = append(Lcol, fmt.Sprintf("%sValid   %s %s%.0fs%s  %spatches %d%s",
		ui.Lbl, ui.Rst, ui.Val, s.ObstructionStats.ValidS, ui.Rst,
		ui.Dim, s.ObstructionStats.PatchesValid, ui.Rst))
	Rcol = append(Rcol, fmt.Sprintf("%sTilt    %s %s%.1f°%s",
		ui.Lbl, ui.Rst, ui.Val, s.AlignmentStats.TiltAngleDeg, ui.Rst))

	Lcol = append(Lcol, fmt.Sprintf("%sBlocked %s %s%.2f%%%s %sof valid time%s",
		ui.Lbl, ui.Rst, ui.Val, timeObsPct, ui.Rst, ui.Dim, ui.Rst))
	Rcol = append(Rcol, fmt.Sprintf("%sAttitude%s %s%s%s",
		ui.Lbl, ui.Rst, ui.Val, dashIf(s.AlignmentStats.AttitudeEstimationState), ui.Rst))

	Lcol = append(Lcol, "")
	Rcol = append(Rcol, "")

	Lcol = append(Lcol, sec("⌖", "Location"))
	Rcol = append(Rcol, sec("⎈", "Link"))

	if loc != nil {
		place, _ := reverseGeocode(context.Background(), loc.LLA.Lat, loc.LLA.Lon)
		if place == "" || place == "unknown" {
			place = dashIf(s.DeviceInfo.CountryCode)
		}
		Lcol = append(Lcol, fmt.Sprintf("%sPlace   %s %s%s%s",
			ui.Lbl, ui.Rst, ui.Val, place, ui.Rst))
		Lcol = append(Lcol, fmt.Sprintf("%sCoords  %s %s%.4f, %.4f%s  %salt %.0fm%s",
			ui.Lbl, ui.Rst, ui.Val, loc.LLA.Lat, loc.LLA.Lon, ui.Rst,
			ui.Dim, loc.LLA.Alt, ui.Rst))
	} else {
		Lcol = append(Lcol, fmt.Sprintf("%sCountry %s %s%s%s",
			ui.Lbl, ui.Rst, ui.Val, dashIf(s.DeviceInfo.CountryCode), ui.Rst))
	}
	gpsColor := ui.OK
	gpsMark := "✓"
	if !s.GpsStats.GpsValid {
		gpsColor = ui.Err
		gpsMark = "✗"
	}
	Lcol = append(Lcol, fmt.Sprintf("%sGPS     %s %s%s lock%s  %s%d sats%s",
		ui.Lbl, ui.Rst, gpsColor, gpsMark, ui.Rst, ui.Dim, s.GpsStats.GpsSats, ui.Rst))

	if havePwNow {
		Rcol = append(Rcol, fmt.Sprintf("%sPower   %s %s%.1f W%s",
			ui.Lbl, ui.Rst, pwColor, pwNow, ui.Rst))
	}
	Rcol = append(Rcol, fmt.Sprintf("%sEthernet%s %s%d Mbps%s",
		ui.Lbl, ui.Rst, ui.Val, s.EthSpeedMbps, ui.Rst))
	Rcol = append(Rcol, fmt.Sprintf("%sService %s %s%s%s",
		ui.Lbl, ui.Rst, svcColor, svcStr, ui.Rst))
	Rcol = append(Rcol, fmt.Sprintf("%sFirmware%s %supdate %s%s",
		ui.Lbl, ui.Rst, ui.Val, dashIf(s.SoftwareUpdateState), ui.Rst))

	// Render
	if L.TwoColumn {
		n := len(Lcol)
		if len(Rcol) > n {
			n = len(Rcol)
		}
		for i := 0; i < n; i++ {
			l, r := "", ""
			if i < len(Lcol) {
				l = Lcol[i]
			}
			if i < len(Rcol) {
				r = Rcol[i]
			}
			fmt.Fprintln(w, ui.Row(l, r, L.LeftColW))
		}
	} else {
		// narrow terminal: stack columns
		for _, l := range Lcol {
			fmt.Fprintln(w, l)
		}
		for _, r := range Rcol {
			fmt.Fprintln(w, r)
		}
	}

	// Sparklines
	if h != nil {
		renderSparklines(w, h, L)
	}

	fmt.Fprintf(w, "\n%s  %s · %s%s\n",
		ui.Dim, envOr("STARLINK_DISH", "192.168.100.1:9200"),
		time.Now().Format("15:04:05"), ui.Rst)
}

func renderSparklines(w io.Writer, h *dish.History, L ui.Layout) {
	pings := h.LastN(h.PopPingLatencyMs, L.SparkW)
	drops := h.LastN(h.PopPingDropRate, L.SparkW)
	dn := h.LastN(h.DownlinkThroughputBps, L.SparkW)
	up := h.LastN(h.UplinkThroughputBps, L.SparkW)
	pw := h.LastN(h.PowerIn, L.SparkW)

	if len(pings) == 0 {
		return
	}

	// Statistic per metric follows one rule: metrics that read zero when idle
	// (throughput) get a peak over a labelled window — never a mean, because an
	// idle dish averages ~0 Mbps on a perfect link and that reads as a fault.
	// Continuously-sampled metrics (ping, drop, power) get a mean.
	pingAvg, _, pingP95 := stats(pings, true)
	dropMax := maxf(drops) * 100
	dnNow, dnMax := lastOf(dn)/1e6, maxf(dn)/1e6
	upNow, upMax := lastOf(up)/1e6, maxf(up)/1e6

	// The span actually plotted, not the span requested. `LastN` used to pad a
	// young dish's ring out to L.SparkW with unwritten zeros, so the two were
	// always equal and printing the request was harmless; now that it returns
	// only written samples, printing the request would caption a 20-second
	// trace "Last 60s". docs/macos-ui.md requires this surface and the app to
	// agree, and the app captions from `seriesSeconds` for exactly this reason.
	covered := shortestSeries(pings, drops, dn, up)
	fmt.Fprintf(w, "\n%s⏱ Last %ds %s%s\n", ui.Hdr, covered, ui.HR(L.Width-14), ui.Rst)
	fmt.Fprintf(w, "  %sPing  %s%s%s  %savg %.1f ms · p95 %.1f ms%s\n",
		ui.Lbl, ui.OK, ui.Spark(pings, 0), ui.Rst, ui.Dim, pingAvg, pingP95, ui.Rst)
	fmt.Fprintf(w, "  %sDrop  %s%s%s  %sper-second loss · peak %.1f%%%s\n",
		ui.Lbl, ui.Err, ui.Spark(drops, 0), ui.Rst, ui.Dim, dropMax, ui.Rst)
	fmt.Fprintf(w, "  %sDL    %s%s%s  %snow %.2f · peak %.2f Mbps%s\n",
		ui.Lbl, ui.OK, ui.Spark(dn, 0), ui.Rst, ui.Dim, dnNow, dnMax, ui.Rst)
	fmt.Fprintf(w, "  %sUL    %s%s%s  %snow %.2f · peak %.2f Mbps%s\n",
		ui.Lbl, ui.OK, ui.Spark(up, 0), ui.Rst, ui.Dim, upNow, upMax, ui.Rst)

	if len(pw) > 0 && maxf(pw) > 0 {
		pwNow := pw[len(pw)-1]
		pwAvg, _ := meanPositive(pw)
		fmt.Fprintf(w, "  %sPower %s%s%s  %snow %.1f W · avg %.1f W%s\n",
			ui.Lbl, ui.Warn, ui.Spark(pw, 0), ui.Rst, ui.Dim, pwNow, pwAvg, ui.Rst)
	}
	pv := loadPersisted()
	renderEnergy(w, L, pv)
	renderObserved(w, L, pv.stats)
}

// persisted is state.json, stats.json and the power-bank anchor read as one
// generation.
//
// They used to be read one at a time, straight from the render functions. Each
// read was individually fine and the combination was not: a poll committing
// between them let the Energy line describe generation N−1 while the Observed
// block four lines below described generation N. That is the same cross-file
// skew the write-side transaction exists to prevent — `lock.go` even cites the
// resulting "obs 21m 8s @ 22.7 W" line as its motivating symptom, and that line
// is printed from here. A shared lock on the read side is the other half of it.
type persisted struct {
	snap   *state.Snapshot
	stats  *state.Stats
	anchor *Anchor
}

func loadPersisted() persisted {
	txn, _ := state.BeginRead()
	defer txn.Close()
	snap, _ := state.Load()
	st, _ := state.LoadStats()
	a, _ := loadAnchor()
	return persisted{snap: snap, stats: st, anchor: a}
}

// renderObserved writes the long-window section fed by stats.json. Every figure
// here covers *observed* samples within the current dish boot — time the CLI
// was not running contributes nothing and is never estimated. The header says
// so, which is why no per-line qualifier is needed.
func renderObserved(w io.Writer, L ui.Layout, st *state.Stats) {
	if !st.Ready() {
		return // too few samples to call these statistics
	}

	// The header carries the caveat so no individual line has to: "observed"
	// makes no claim about the time the CLI was not running, and naming the
	// uptime alongside it shows how much of this boot went unwatched.
	hdr := fmt.Sprintf("📊 Observed %s", state.HumanDur(st.ObservedSeconds()))
	if st.Coverage() < 0.95 {
		hdr += fmt.Sprintf(" of %s uptime", state.HumanDur(st.LastUptimeS))
	} else {
		hdr += " · all of this boot"
	}
	pad := L.Width - ui.VisibleLen(hdr) - 3
	if pad < 0 {
		pad = 0
	}
	fmt.Fprintf(w, "\n%s%s %s%s\n", ui.Hdr, hdr, ui.HR(pad), ui.Rst)

	// Latency is averaged over seconds where a packet actually returned; loss is
	// reported as clean-second share plus outage events, because on a moving
	// dish the distribution is bimodal and its mean names a state that never
	// happened. See docs/macos-ui.md.
	// Label field is 7 wide here, not the 6 used above: "Outage" fills six
	// exactly and still needs a separator, so a 6-wide field would leave this
	// one line indented a column further than its neighbours.
	fmt.Fprintf(w, "  %sLink   %s%sping %.1f ms · %.0f%% clean · %.0f%% degraded · %.0f%% dark%s\n",
		ui.Lbl, ui.Rst, ui.Dim, st.PingAvg(),
		st.CleanPct(), st.DegradedPct(), st.DarkPct(), ui.Rst)
	if n := st.Outages(); n > 0 {
		fmt.Fprintf(w, "  %sOutage %s%s%d · %s dark · longest %s%s\n",
			ui.Lbl, ui.Rst, ui.Dim, n,
			state.HumanDur(st.OutageSeconds), state.HumanDur(st.LongestOutage()), ui.Rst)
	} else {
		fmt.Fprintf(w, "  %sOutage %s%snone%s\n", ui.Lbl, ui.Rst, ui.Dim, ui.Rst)
	}
	fmt.Fprintf(w, "  %sPeak   %s%s↓ %.2f Mbps  ↑ %.2f Mbps%s\n",
		ui.Lbl, ui.Rst, ui.Dim, st.DownPeakMbps(), st.UpPeakMbps(), ui.Rst)
	fmt.Fprintf(w, "  %sData   %s%s↓ %s  ↑ %s%s\n",
		ui.Lbl, ui.Rst, ui.Dim, humanBytes(st.DownBytes()), humanBytes(st.UpBytes()), ui.Rst)
	if st.PowerCount > 0 {
		// The Wh here is this block's own energy, integrated from the same
		// samples as the average beside it — not the since-boot total on the
		// Energy line above, which is a different accumulator over a different
		// window. Two figures, two questions; stating them in one place would
		// invite reading either as the other.
		fmt.Fprintf(w, "  %sPower  %s%savg %.1f W · peak %.1f W · %.1f Wh used%s\n",
			ui.Lbl, ui.Rst, ui.Dim, st.PowerAvg(), st.PowerMax, st.EnergyWh(), ui.Rst)
	}
}

// renderEnergy writes the Energy (and optional Bank) lines, derived from
// the persisted snapshot's accumulator.
func renderEnergy(w io.Writer, L ui.Layout, pv persisted) {
	snap := pv.snap
	if snap == nil || snap.EnergyWh <= 0 {
		return
	}
	upStr := state.HumanDur(snap.UptimeS)
	avgW, haveAvg := snap.ObservedAvgW()

	switch {
	case !haveAvg:
		// A snapshot from before the sample counter existed. We hold a total
		// but no honest denominator, so quote the total and nothing else
		// rather than divide by wall clock.
		fmt.Fprintf(w, "  %sEnergy%s %s%.2f Wh%s  %sover %s%s\n",
			ui.Lbl, ui.Rst, ui.Val, snap.EnergyWh, ui.Rst, ui.Dim, upStr, ui.Rst)
	case snap.ObservedCoversBoot():
		fmt.Fprintf(w, "  %sEnergy%s %s%.2f Wh%s  %ssince boot (%s) · avg %.1f W%s\n",
			ui.Lbl, ui.Rst, ui.Val, snap.EnergyWh, ui.Rst, ui.Dim, upStr, avgW, ui.Rst)
	default:
		obsStr := state.HumanDur(snap.ObsSeconds)
		estWh := snap.EnergyWh * float64(snap.UptimeS) / float64(snap.ObsSeconds)
		fmt.Fprintf(w, "  %sEnergy%s %s%.2f Wh%s  %sobs %s @ %.1f W · est %.1f Wh over %s%s\n",
			ui.Lbl, ui.Rst, ui.Val, snap.EnergyWh, ui.Rst, ui.Dim, obsStr, avgW, estWh, upStr, ui.Rst)
	}
	renderBank(w, L, pv, avgW)
}

// renderBank draws the power-bank depletion line if an anchor or env override
// is set. Implemented fully in pb.go (this is a stub satisfied at link time).
var renderBank = func(w io.Writer, L ui.Layout, pv persisted, avgW float64) {}

// ----- helpers -----

func signalScore(s *dish.Status) int {
	p := s.PopPingLatencyMs
	d := s.PopPingDropRate
	o := s.ObstructionStats.FractionObstructed
	ps := (150 - p) / 150
	ps = clampF(ps, 0, 1)
	ds := clampF(1-d, 0, 1)
	os := clampF(1-o, 0, 1)
	score := 100 * ps * ds * os
	if !s.IsSnrAboveNoiseFloor || s.IsSnrPersistentlyLow {
		score *= 0.5
	}
	if score < 0 {
		score = 0
	}
	if score > 100 {
		score = 100
	}
	return int(math.Round(score))
}

func serviceStatus(code string) (string, string) {
	switch code {
	case "OKAY":
		return "active ✓", ui.OK
	case "NO_ACTIVE_ACCOUNT":
		return "no account", ui.Err
	case "SUSPENDED":
		return "suspended (billing)", ui.Err
	case "OUT_OF_SERVICE_AREA":
		return "outside plan area", ui.Err
	case "OUT_OF_REGION":
		return "wrong region", ui.Err
	case "DISABLED_BY_COMMAND":
		return "disabled by SpaceX", ui.Err
	case "UNKNOWN_USER_TERMINAL":
		return "unrecognized dish", ui.Err
	case "INVALID_HARDWARE_VERSION":
		return "firmware invalid", ui.Err
	case "":
		return "?", ui.Warn
	default:
		return code, ui.Warn
	}
}

func readyKeysCompact(m map[string]bool) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := ""
	for i, k := range keys {
		if i > 0 {
			out += " "
		}
		out += k
	}
	return out
}

func stats(vs []float64, positiveOnly bool) (avg, max, p95 float64) {
	var filtered []float64
	for _, v := range vs {
		if !positiveOnly || v > 0 {
			filtered = append(filtered, v)
		}
	}
	if len(filtered) == 0 {
		return 0, 0, 0
	}
	sum := 0.0
	for _, v := range filtered {
		sum += v
		if v > max {
			max = v
		}
	}
	avg = sum / float64(len(filtered))
	sorted := append([]float64(nil), filtered...)
	sort.Float64s(sorted)
	idx := int(float64(len(sorted)) * 0.95)
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	p95 = sorted[idx]
	return
}

func mean(vs []float64) float64 {
	if len(vs) == 0 {
		return 0
	}
	s := 0.0
	for _, v := range vs {
		s += v
	}
	return s / float64(len(vs))
}

func meanPositive(vs []float64) (avg, max float64) {
	n := 0
	s := 0.0
	for _, v := range vs {
		if v > 0 {
			s += v
			n++
			if v > max {
				max = v
			}
		}
	}
	if n == 0 {
		return 0, 0
	}
	return s / float64(n), max
}

func lastOf(vs []float64) float64 {
	if len(vs) == 0 {
		return 0
	}
	return vs[len(vs)-1]
}

// humanBytes formats a byte count with a decimal (SI) prefix — the convention
// ISPs and speed tests use, so the number matches what a data cap is quoted in.
func humanBytes(b float64) string {
	switch {
	case b >= 1e12:
		return fmt.Sprintf("%.2f TB", b/1e12)
	case b >= 1e9:
		return fmt.Sprintf("%.2f GB", b/1e9)
	case b >= 1e6:
		return fmt.Sprintf("%.1f MB", b/1e6)
	case b >= 1e3:
		return fmt.Sprintf("%.0f kB", b/1e3)
	default:
		return fmt.Sprintf("%.0f B", b)
	}
}

func maxf(vs []float64) float64 {
	m := 0.0
	for _, v := range vs {
		if v > m {
			m = v
		}
	}
	return m
}

func clampF(v, lo, hi float64) float64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func dashIf(s string) string {
	if s == "" {
		return "?"
	}
	return s
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
