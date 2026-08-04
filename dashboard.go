package main

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"time"

	"github.com/faeton/dishwatch/internal/dish"
	"github.com/faeton/dishwatch/internal/state"
)

// Dashboard is the JSON contract consumed by the macOS app's `LiveProvider`.
// Field names (and JSON tags) match the Swift `DishData` struct 1:1 so the app
// can decode it directly. See app/Sources/DishWatch/Model/DishData.swift.
type Dashboard struct {
	State             string    `json:"state"`
	SignalScore       int       `json:"signalScore"`
	UptimeHours       float64   `json:"uptimeHours"`
	Boots             int       `json:"boots"`
	HardwareShort     string    `json:"hardwareShort"`
	DeviceID          string    `json:"deviceId"`
	Firmware          string    `json:"firmware"`
	DownMbps          float64   `json:"downMbps"`
	UpMbps            float64   `json:"upMbps"`
	PingMs            float64   `json:"pingMs"`
	DropPct           float64   `json:"dropPct"`
	NoiseOK           bool      `json:"noiseOK"`
	DownBarFrac       float64   `json:"downBarFrac"`
	UpBarFrac         float64   `json:"upBarFrac"`
	AzimuthDeg        float64   `json:"azimuthDeg"`
	ElevationDeg      float64   `json:"elevationDeg"`
	GpsValid          bool      `json:"gpsValid"`
	GpsSats           int       `json:"gpsSats"`
	EthMbps           int       `json:"ethMbps"`
	PowerW            float64   `json:"powerW"`
	EnergyWhSinceBoot float64   `json:"energyWhSinceBoot"`
	PingSeries        []float64 `json:"pingSeries"`
	PingAvg           float64   `json:"pingAvg"`
	DownSeries        []float64 `json:"downSeries"`
	DownMax           float64   `json:"downMax"`
	DownAvg           float64   `json:"downAvg"`
	UpSeries          []float64 `json:"upSeries"`
	UpAvg             float64   `json:"upAvg"`
	PowerSeries       []float64 `json:"powerSeries"`
	PowerAvg          float64   `json:"powerAvg"`
	// Observed-session aggregates from stats.json. Unlike the fields above
	// (which are 60-second window figures off the dish's ring buffer) these
	// cover every sample seen during the current dish boot. Note the deliberate
	// absence of a session mean for down/up: mean throughput measures how much
	// was used, not how fast the link is, so only peak and total volume are
	// exposed. See docs/macos-ui.md.
	ObsSeconds  int64   `json:"obsSeconds"`
	ObsCoverage float64 `json:"obsCoverage"` // observed ÷ uptime, 0..1
	SessPingAvg float64 `json:"sessPingAvg"` // seconds with a returned packet only
	SessDropAvg float64 `json:"sessDropAvg"` // percent — poor summary, prefer clean/outages

	// Loss segmented into events. On a moving dish the link is either clean or
	// fully dark, so these describe it and the mean above does not.
	SessCleanPct      float64 `json:"sessCleanPct"`
	SessOutages       int64   `json:"sessOutages"`
	SessOutageSeconds int64   `json:"sessOutageSeconds"`
	SessLongestOutage int64   `json:"sessLongestOutage"`
	SessDownPeak      float64 `json:"sessDownPeak"`
	SessUpPeak        float64 `json:"sessUpPeak"`
	SessDownBytes     float64 `json:"sessDownBytes"`
	SessUpBytes       float64 `json:"sessUpBytes"`
	SessPowerAvg      float64 `json:"sessPowerAvg"`
	SessPowerPeak     float64 `json:"sessPowerPeak"`

	DishAddr        string  `json:"dishAddr"`
	OnBattery       bool    `json:"onBattery"`
	BankAnchored    bool    `json:"bankAnchored"`
	BankPct         float64 `json:"bankPct"`
	BankWh          float64 `json:"bankWh"`
	BankWhLeft      float64 `json:"bankWhLeft"`
	BankSecondsLeft int     `json:"bankSecondsLeft"`
	AnchoredAgoText string  `json:"anchoredAgoText"`
}

// runJSON implements `dishwatch json`: emit one Dashboard snapshot as JSON. On
// an unreachable dish it emits a minimal Offline dashboard from the last
// persisted snapshot so the app can show a stale state instead of erroring.
func runJSON(ctx context.Context) error {
	addr := envOr("STARLINK_DISH", "192.168.100.1:9200")
	c, err := dialDish(ctx)
	if err != nil {
		_ = state.MarkUnreachable(addr)
		return emit(offlineDashboard(addr))
	}
	defer c.Close()

	s, h, err := fetchDash(ctx, c) // also integrates energy + saves state
	if err != nil {
		_ = state.MarkUnreachable(addr)
		return emit(offlineDashboard(addr))
	}
	loc, _ := c.GetLocation(ctx)
	return emit(buildDashboard(s, h, loc, addr))
}

func emit(d Dashboard) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	return enc.Encode(d)
}

func offlineDashboard(addr string) Dashboard {
	d := Dashboard{State: "Offline", DishAddr: addr}
	if snap, _ := state.Load(); snap != nil {
		d.Boots = snap.Boots
		d.UptimeHours = float64(snap.UptimeS) / 3600
		d.PingMs = snap.Ping
		d.DropPct = snap.Drop * 100
		d.EnergyWhSinceBoot = snap.EnergyWh
	}
	return d
}

func buildDashboard(s *dish.Status, h *dish.History, loc *dish.Location, addr string) Dashboard {
	d := Dashboard{
		State:         swiftState(derivedState(s)),
		SignalScore:   signalScore(s),
		UptimeHours:   float64(s.DeviceState.UptimeS) / 3600,
		Boots:         int(s.DeviceInfo.Bootcount),
		HardwareShort: hardwareShort(s.DeviceInfo.HardwareVersion),
		DeviceID:      s.DeviceInfo.HardwareVersion,
		Firmware:      trimFirmware(s.DeviceInfo.SoftwareVersion),
		DownMbps:      round1(s.DownlinkThroughputBps / 1e6),
		UpMbps:        round1(s.UplinkThroughputBps / 1e6),
		PingMs:        round1(s.PopPingLatencyMs),
		DropPct:       round1(s.PopPingDropRate * 100),
		NoiseOK:       s.IsSnrAboveNoiseFloor && !s.IsSnrPersistentlyLow,
		DownBarFrac:   clampF(s.DownlinkThroughputBps/2e8, 0, 1),
		UpBarFrac:     clampF(s.UplinkThroughputBps/4e7, 0, 1),
		AzimuthDeg:    s.BoresightAzimuthDeg,
		ElevationDeg:  s.BoresightElevationDeg,
		GpsValid:      s.GpsStats.GpsValid,
		GpsSats:       s.GpsStats.GpsSats,
		EthMbps:       s.EthSpeedMbps,
		DishAddr:      addr,
	}

	if h != nil {
		const w = 60
		d.PingSeries = h.LastN(h.PopPingLatencyMs, w)
		d.DownSeries = toMbps(h.LastN(h.DownlinkThroughputBps, w))
		d.UpSeries = toMbps(h.LastN(h.UplinkThroughputBps, w))
		d.PowerSeries = h.LastN(h.PowerIn, w)
		d.PingAvg = round1(nonzeroMean(d.PingSeries))
		d.DownAvg = round1(mean(d.DownSeries))
		d.DownMax = round1(maxf(d.DownSeries))
		d.UpAvg = round1(mean(d.UpSeries))
		if pw, ok := h.Latest(h.PowerIn); ok {
			d.PowerW = round1(pw)
		}
		_, pwAvg := meanPositive(d.PowerSeries)
		d.PowerAvg = round1(pwAvg)
	}

	// Read both persisted files under one shared lock: they are advanced by a
	// single transaction, so loading them separately can otherwise straddle a
	// commit and emit generation-N session stats beside generation-N-1 energy.
	rtxn, _ := state.BeginRead()
	defer rtxn.Close()

	if st, _ := state.LoadStats(); st.Ready() {
		d.ObsSeconds = st.ObservedSeconds()
		d.ObsCoverage = st.Coverage()
		d.SessPingAvg = round1(st.PingAvg())
		d.SessDropAvg = round1(st.DropAvgPct())
		d.SessCleanPct = round1(st.CleanPct())
		d.SessOutages = st.Outages()
		d.SessOutageSeconds = st.OutageSeconds
		d.SessLongestOutage = st.LongestOutage()
		d.SessDownPeak = round1(st.DownPeakMbps())
		d.SessUpPeak = round1(st.UpPeakMbps())
		d.SessDownBytes = st.DownBytes()
		d.SessUpBytes = st.UpBytes()
		d.SessPowerAvg = round1(st.PowerAvg())
		d.SessPowerPeak = round1(st.PowerMax)
	}

	// Power-bank: only populated when an anchor is set (sl pb). With pb
	// disabled there is no anchor → onBattery=false, bankAnchored=false.
	if snap, _ := state.Load(); snap != nil {
		d.EnergyWhSinceBoot = round1(snap.EnergyWh)
		fillBank(&d, snap)
	}
	return d
}

// fillBank mirrors pb.go's pbRenderBank anchor branch.
func fillBank(d *Dashboard, snap *state.Snapshot) {
	a, _ := loadAnchor()
	if a == nil || a.Wh <= 0 || a.Boots != snap.Boots {
		return // no usable anchor → stay on mains
	}
	d.OnBattery = true
	d.BankAnchored = true
	d.BankWh = a.Wh

	usedWh := snap.EnergyWh - a.EnergyWh
	if usedWh < 0 {
		usedWh = 0
	}
	pctLeft := a.Pct - usedWh*100/a.Wh
	if pctLeft < 0 {
		pctLeft = 0
	}
	d.BankPct = round1(pctLeft)
	whLeft := a.Wh * pctLeft / 100
	d.BankWhLeft = round1(whLeft)

	now := time.Now().Unix()
	obsDur := now - snap.ObsStartTs
	if obsDur < 1 {
		obsDur = 1
	}
	avgW := snap.EnergyWh * 3600 / float64(obsDur)
	if avgW > 0 {
		d.BankSecondsLeft = int(whLeft * 3600 / avgW)
	}
	d.AnchoredAgoText = state.HumanDur(now-a.TS) + " ago"
}

// ----- small helpers -----

func toMbps(v []float64) []float64 {
	out := make([]float64, len(v))
	for i, x := range v {
		out[i] = round1(x / 1e6)
	}
	return out
}

func round1(v float64) float64 { return float64(int(v*10+0.5)) / 10 }

func hardwareShort(hw string) string {
	l := strings.ToLower(hw)
	switch {
	case strings.Contains(l, "mini"):
		return "Mini"
	case strings.Contains(l, "rev3"), strings.Contains(l, "rev4"), strings.Contains(l, "standard"):
		return "Standard"
	case hw == "":
		return "?"
	default:
		return hw
	}
}

// swiftState maps the CLI's UPPERCASE derived state to the title-case strings
// the macOS app's LinkState enum decodes ("Connected"/"Disabled"/"Weak").
func swiftState(s string) string {
	switch s {
	case "CONNECTED":
		return "Connected"
	case "DISABLED":
		return "Disabled"
	default: // NOT READY / BOOTING / SEARCHING / etc. — online but not solid
		return "Weak"
	}
}

func trimFirmware(sw string) string {
	parts := strings.Split(sw, ".")
	if len(parts) >= 3 {
		return strings.Join(parts[:3], ".")
	}
	return sw
}
