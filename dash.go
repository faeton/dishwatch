package main

import (
	"context"
	"fmt"
	"math"
	"os"
	"sort"
	"time"

	"github.com/faeton/dishwatch/internal/dish"
	"github.com/faeton/dishwatch/internal/ui"
)

func runDash(ctx context.Context) error {
	c, err := dialDish(ctx)
	if err != nil {
		return renderUnreachable(ctx, err)
	}
	defer c.Close()

	// Fetch status + history in parallel — they're independent.
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
		return renderUnreachable(ctx, sr.err)
	}
	s := sr.s
	h := hr.h // may be nil if history fetch failed; handled below

	L := ui.DetectLayout()
	renderDash(s, h, L)
	return nil
}

func renderUnreachable(_ context.Context, err error) error {
	fmt.Printf("\x1b[H\x1b[J\n")
	fmt.Printf("  %sStarlink%s  %s● UNREACHABLE%s\n",
		ui.Hdr, ui.Rst, ui.Err, ui.Rst)
	fmt.Printf("  %s%v%s\n", ui.Dim, err, ui.Rst)
	return nil
}

func renderDash(s *dish.Status, h *dish.History, L ui.Layout) {
	// Clear screen unless we're inside a watch loop (caller positions cursor).
	// We don't have a watch yet — always clear.
	fmt.Print("\x1b[H\x1b[J\n")

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
	fmt.Printf("  %sStarlink%s  %s●%s %s%s  %s%s · %s · %s%s  %sup %.1fh · boots %d%s\n",
		ui.Hdr, ui.Rst, dotColor, ui.Rst, ui.Val, state,
		ui.Dim, dashIf(s.ClassOfService), dashIf(s.MobilityClass), dashIf(s.DeviceInfo.CountryCode), ui.Rst,
		ui.Dim, upH, s.DeviceInfo.Bootcount, ui.Rst)
	fmt.Printf("  %s%s · fw %s%s\n\n",
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
			fmt.Println(ui.Row(l, r, L.LeftColW))
		}
	} else {
		// narrow terminal: stack columns
		for _, l := range Lcol {
			fmt.Println(l)
		}
		for _, r := range Rcol {
			fmt.Println(r)
		}
	}

	// Sparklines
	if h != nil {
		renderSparklines(h, L)
	}

	fmt.Printf("\n%s  %s · %s%s\n",
		ui.Dim, envOr("STARLINK_DISH", "192.168.100.1:9200"),
		time.Now().Format("15:04:05"), ui.Rst)
}

func renderSparklines(h *dish.History, L ui.Layout) {
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

	fmt.Printf("\n%s⏱ Last %ds %s%s\n", ui.Hdr, L.SparkW, ui.HR(L.Width-14), ui.Rst)
	fmt.Printf("  %sPing  %s%s%s  %savg %.1f ms · max %.1f ms · p95 %.1f ms · drop %.1f%%%s\n",
		ui.Lbl, ui.OK, ui.Spark(pings, 0), ui.Rst, ui.Dim, pingAvg, pingMax, pingP95, dropAvg, ui.Rst)
	fmt.Printf("  %sDrop  %s%s%s  %sper-second loss · peak %.1f%%%s\n",
		ui.Lbl, ui.Err, ui.Spark(drops, 0), ui.Rst, ui.Dim, dropMax, ui.Rst)
	fmt.Printf("  %sDown  %s%s%s  %savg %.2f Mbps  max %.2f Mbps%s\n",
		ui.Lbl, ui.OK, ui.Spark(dn, 0), ui.Rst, ui.Dim, dnAvg, dnMax, ui.Rst)
	fmt.Printf("  %sUp    %s%s%s  %savg %.2f Mbps  max %.2f Mbps%s\n",
		ui.Lbl, ui.OK, ui.Spark(up, 0), ui.Rst, ui.Dim, upAvg, upMax, ui.Rst)

	if len(pw) > 0 && maxf(pw) > 0 {
		pwNow := pw[len(pw)-1]
		pwAvg, pwMax := meanPositive(pw)
		fmt.Printf("  %sPower %s%s%s  %snow %.1f W  avg %.1f W  max %.1f W%s\n",
			ui.Lbl, ui.Warn, ui.Spark(pw, 0), ui.Rst, ui.Dim, pwNow, pwAvg, pwMax, ui.Rst)
	}
}

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
