package main

import (
	"context"
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

	s, h, err := fetchDash(ctx, c)
	if err != nil {
		_ = state.MarkUnreachable(envOr("STARLINK_DISH", "192.168.100.1:9200"))
		return renderUnreachable(os.Stdout, false, err)
	}
	L := ui.DetectLayout()
	renderDash(os.Stdout, s, h, L, false)
	return nil
}

// fetchDash fetches status + history in parallel. history may be nil if that
// call failed; status failure is fatal.
func fetchDash(ctx context.Context, c *dish.Client) (*dish.Status, *dish.History, error) {
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
		return nil, nil, sr.err
	}
	snapshotAndLog(sr.s, hr.h)
	return sr.s, hr.h, nil
}

// snapshotAndLog compares the new snapshot against the persisted one, updates
// the energy accumulator from get_history.powerIn, writes transition events,
// then replaces state.json.
func snapshotAndLog(s *dish.Status, h *dish.History) {
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
	cur.EnergyWh, cur.LastCurrent, cur.ObsStartTs, cur.ObsStartUptime =
		integrateEnergy(s, h, prev, now)
	_ = state.DiffAndLog(cur, prev)
	_ = state.Save(cur)
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
func integrateEnergy(s *dish.Status, h *dish.History, prev *state.Snapshot, now int64) (energyWh float64, lastCur, obsStartTs, obsStartUp int64) {
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
	}

	reboot := prev == nil || boots != prevBoots || (prevUptime >= 0 && uptime < prevUptime)

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
			if obsStartUp < 0 {
				obsStartUp = 0
			}
			lastCur = cur
		} else if lastCur > 0 {
			delta := cur - lastCur
			if delta > 0 && delta <= ringLen {
				var joules float64
				for i := cur - delta; i < cur; i++ {
					joules += h.PowerIn[((i%ringLen)+ringLen)%ringLen]
				}
				energyWh += joules / 3600
				lastCur = cur
			} else if delta > ringLen {
				// Gap bigger than the ring — samples lost, keep accumulator.
				lastCur = cur
			}
		} else {
			// First observation without a reboot and without a prior cursor.
			lastCur = cur
			if obsStartTs == 0 {
				obsStartTs = now
			}
			if obsStartUp == 0 {
				obsStartUp = uptime
			}
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

func renderDash(w io.Writer, s *dish.Status, h *dish.History, L ui.Layout, inWatch bool) {
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
	Rcol = append(Rcol, fmt.Sprintf("%sDown    %s %s  %s%.2f Mbps%s",
		ui.Lbl, ui.Rst, ui.Bar(dnBarPct, L.BarW, ""), ui.Val, downMbps, ui.Rst))

	readyShort := ui.OK + "✓ all" + ui.Rst
	if !allTrue(s.ReadyStates) {
		readyShort = ui.Err + "not ready" + ui.Rst
	}
	Lcol = append(Lcol, fmt.Sprintf("%sReady   %s %s  %s%s%s",
		ui.Lbl, ui.Rst, readyShort, ui.Dim, readyKeysCompact(s.ReadyStates), ui.Rst))
	Rcol = append(Rcol, fmt.Sprintf("%sUp      %s %s  %s%.2f Mbps%s",
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

	Lcol = append(Lcol, fmt.Sprintf("%sCountry %s %s%s%s",
		ui.Lbl, ui.Rst, ui.Val, dashIf(s.DeviceInfo.CountryCode), ui.Rst))
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

	pingAvg, pingMax, pingP95 := stats(pings, true)
	dropAvg := mean(drops) * 100
	dropMax := maxf(drops) * 100
	dnAvg := mean(dn) / 1e6
	dnMax := maxf(dn) / 1e6
	upAvg := mean(up) / 1e6
	upMax := maxf(up) / 1e6

	fmt.Fprintf(w, "\n%s⏱ Last %ds %s%s\n", ui.Hdr, L.SparkW, ui.HR(L.Width-14), ui.Rst)
	fmt.Fprintf(w, "  %sPing  %s%s%s  %savg %.1f ms · max %.1f ms · p95 %.1f ms · drop %.1f%%%s\n",
		ui.Lbl, ui.OK, ui.Spark(pings, 0), ui.Rst, ui.Dim, pingAvg, pingMax, pingP95, dropAvg, ui.Rst)
	fmt.Fprintf(w, "  %sDrop  %s%s%s  %sper-second loss · peak %.1f%%%s\n",
		ui.Lbl, ui.Err, ui.Spark(drops, 0), ui.Rst, ui.Dim, dropMax, ui.Rst)
	fmt.Fprintf(w, "  %sDown  %s%s%s  %savg %.2f Mbps  max %.2f Mbps%s\n",
		ui.Lbl, ui.OK, ui.Spark(dn, 0), ui.Rst, ui.Dim, dnAvg, dnMax, ui.Rst)
	fmt.Fprintf(w, "  %sUp    %s%s%s  %savg %.2f Mbps  max %.2f Mbps%s\n",
		ui.Lbl, ui.OK, ui.Spark(up, 0), ui.Rst, ui.Dim, upAvg, upMax, ui.Rst)

	if len(pw) > 0 && maxf(pw) > 0 {
		pwNow := pw[len(pw)-1]
		pwAvg, pwMax := meanPositive(pw)
		fmt.Fprintf(w, "  %sPower %s%s%s  %snow %.1f W  avg %.1f W  max %.1f W%s\n",
			ui.Lbl, ui.Warn, ui.Spark(pw, 0), ui.Rst, ui.Dim, pwNow, pwAvg, pwMax, ui.Rst)
	}
	renderEnergy(w, L)
}

// renderEnergy writes the Energy (and optional Bank) lines, derived from
// the persisted snapshot's accumulator.
func renderEnergy(w io.Writer, L ui.Layout) {
	snap, err := state.Load()
	if err != nil || snap == nil || snap.EnergyWh <= 0 {
		return
	}
	now := time.Now().Unix()
	obsDur := now - snap.ObsStartTs
	if obsDur < 1 {
		obsDur = 1
	}
	avgW := snap.EnergyWh * 3600 / float64(obsDur)
	estWh := snap.EnergyWh * float64(snap.UptimeS) / float64(obsDur)
	obsStr := state.HumanDur(obsDur)
	upStr := state.HumanDur(snap.UptimeS)

	if obsDur*100 >= snap.UptimeS*95 {
		fmt.Fprintf(w, "  %sEnergy%s %s%.2f Wh%s  %ssince boot (%s) · avg %.1f W%s\n",
			ui.Lbl, ui.Rst, ui.Val, snap.EnergyWh, ui.Rst, ui.Dim, upStr, avgW, ui.Rst)
	} else {
		fmt.Fprintf(w, "  %sEnergy%s %s%.2f Wh%s  %sobs %s @ %.1f W · est %.1f Wh over %s%s\n",
			ui.Lbl, ui.Rst, ui.Val, snap.EnergyWh, ui.Rst, ui.Dim, obsStr, avgW, estWh, upStr, ui.Rst)
	}
	renderBank(w, L, snap, avgW)
}

// renderBank draws the power-bank depletion line if an anchor or env override
// is set. Implemented fully in pb.go (this is a stub satisfied at link time).
var renderBank = func(w io.Writer, L ui.Layout, snap *state.Snapshot, avgW float64) {}

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
