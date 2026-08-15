package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/faeton/dishwatch/internal/dish"
	"github.com/faeton/dishwatch/internal/state"
)

// DashboardSchemaVersion is the version of the JSON contract below. Keep it in
// step with `DishData.expectedSchema` in
// app/Sources/DishWatch/Model/DishData.swift; scripts/check-contract.sh fails
// the build if the two drift, along with any key that exists on one side only.
const DashboardSchemaVersion = 1

// Dashboard is the JSON contract consumed by the macOS app's `LiveProvider`.
// Field names (and JSON tags) match the Swift `DishData` struct 1:1 so the app
// can decode it directly. See app/Sources/DishWatch/Model/DishData.swift.
type Dashboard struct {
	// SchemaVersion is bumped whenever a field this DTO already emits changes
	// meaning, type or name. Adding a field does not bump it — the Swift side
	// ignores unknown keys by design, so additions are compatible.
	//
	// The helper's `protocol` number versions the *envelope* (id/ok/data/error)
	// and says nothing about the payload, so a Dashboard field rename used to
	// need no bump anywhere and raised nothing on either side. `dishwatch json`
	// has no envelope at all, which is the other reason this belongs here.
	SchemaVersion int `json:"schemaVersion"`

	State         string  `json:"state"`
	SignalScore   int     `json:"signalScore"`
	UptimeHours   float64 `json:"uptimeHours"`
	Boots         int     `json:"boots"`
	HardwareShort string  `json:"hardwareShort"`
	// How the panel gets pointed: "motorized", "manual", or "" for a model
	// this build does not recognise. Derived from the model name because the
	// dish will not say — `dish_get_context`, which carries the actuator flag
	// directly, answers PermissionDenied to an unauthenticated caller, and
	// `get_status` has no such field at any permission level. See
	// classifyHardware for why that inference is sound enough to display.
	HardwareAim       string  `json:"hardwareAim"`
	DeviceID          string  `json:"deviceId"`
	Firmware          string  `json:"firmware"`
	DownMbps          float64 `json:"downMbps"`
	UpMbps            float64 `json:"upMbps"`
	PingMs            float64 `json:"pingMs"`
	DropPct           float64 `json:"dropPct"`
	NoiseOK           bool    `json:"noiseOK"`
	DownBarFrac       float64 `json:"downBarFrac"`
	UpBarFrac         float64 `json:"upBarFrac"`
	AzimuthDeg        float64 `json:"azimuthDeg"`
	ElevationDeg      float64 `json:"elevationDeg"`
	GpsValid          bool    `json:"gpsValid"`
	GpsSats           int     `json:"gpsSats"`
	EthMbps           int     `json:"ethMbps"`
	PowerW            float64 `json:"powerW"`
	EnergyWhSinceBoot float64 `json:"energyWhSinceBoot"`
	// What the energy total may honestly be *called*, mirroring the three cases
	// `renderEnergy` picks between. The app used to label it "Wh since boot"
	// unconditionally, which is only true when the samples we hold cover the
	// boot: the accumulator integrates retrieved samples, so after any gap the
	// figure is an under-count presented as a total. On this machine that was
	// 90 Wh shown as the since-boot draw of a dish that had actually used ~900.
	//
	// EnergyAvgW is 0 when no honest average exists — either nothing is counted
	// yet, or the count and the total are inconsistent (see MaxPlausibleW).
	EnergyCoversBoot bool      `json:"energyCoversBoot"`
	EnergySeconds    int64     `json:"energySeconds"`
	EnergyAvgW       float64   `json:"energyAvgW"`
	PingSeries       []float64 `json:"pingSeries"`
	PingAvg          float64   `json:"pingAvg"`
	DownSeries       []float64 `json:"downSeries"`
	DownMax          float64   `json:"downMax"`
	DownAvg          float64   `json:"downAvg"`
	UpSeries         []float64 `json:"upSeries"`
	UpAvg            float64   `json:"upAvg"`
	PowerSeries      []float64 `json:"powerSeries"`
	PowerAvg         float64   `json:"powerAvg"`
	// SeriesSeconds is how many samples the series above actually carry — which
	// is not always the window that was asked for. The dish's ring is one sample
	// per second but only as deep as the dish has been up, so a request for 15
	// minutes two minutes after a reboot returns 120 points. The caller labels
	// from this, never from its own request, or a freshly-booted dish gets a
	// two-minute trace captioned "15 m".
	SeriesSeconds int `json:"seriesSeconds"`
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
	// Three-way, not two: the band between clean and dark is mostly 20–90%
	// loss, so folding it into either neighbour misrepresents it.
	SessCleanPct      float64 `json:"sessCleanPct"`
	SessDegradedPct   float64 `json:"sessDegradedPct"`
	SessDarkPct       float64 `json:"sessDarkPct"`
	SessOutages       int64   `json:"sessOutages"`
	SessOutageSeconds int64   `json:"sessOutageSeconds"`
	SessLongestOutage int64   `json:"sessLongestOutage"`
	SessDownPeak      float64 `json:"sessDownPeak"`
	SessUpPeak        float64 `json:"sessUpPeak"`
	SessDownBytes     float64 `json:"sessDownBytes"`
	SessUpBytes       float64 `json:"sessUpBytes"`
	SessPowerAvg      float64 `json:"sessPowerAvg"`
	SessPowerPeak     float64 `json:"sessPowerPeak"`
	// Energy across the samples this block describes — PowerSum is watt-seconds,
	// so it is an exact integration rather than an average times a duration.
	// Distinct from EnergyWhSinceBoot above, which is a separate accumulator
	// over a separate window; the two answer different questions.
	SessEnergyWh float64 `json:"sessEnergyWh"`

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
//
// `--window <seconds>` widens the sparkline series off the dish's own ring,
// 60–900. It exists mainly for the development `LiveProvider`, which reaches
// the engine through this command rather than through the helper protocol; the
// shipped app asks the helper directly.
func runJSON(ctx context.Context, args []string) error {
	window := defaultSeriesWindow
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--window", "-w":
			if i+1 >= len(args) {
				return fmt.Errorf("--window needs a value in seconds")
			}
			n, err := strconv.Atoi(args[i+1])
			if err != nil {
				return fmt.Errorf("--window: %w", err)
			}
			window = n
			i++
		default:
			return fmt.Errorf("json: unknown argument %q", args[i])
		}
	}
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
	return emit(buildDashboard(s, h, addr, window))
}

func emit(d Dashboard) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	return enc.Encode(d)
}

func offlineDashboard(addr string) Dashboard {
	d := Dashboard{SchemaVersion: DashboardSchemaVersion, State: "Offline", DishAddr: addr}
	if snap, _ := state.Load(); snap != nil {
		d.Boots = snap.Boots
		d.UptimeHours = float64(snap.UptimeS) / 3600
		d.PingMs = snap.Ping
		d.DropPct = snap.Drop * 100
		d.EnergyWhSinceBoot = snap.EnergyWh
	}
	return d
}

// buildDashboard maps a status + history pair into the DTO the app decodes.
//
// It deliberately takes no location. It used to accept a *dish.Location that it
// never referenced, so both callers paid a full get_location round trip per
// poll — roughly a third of the poll's dish time — to fill a parameter that was
// discarded. Go does not warn on unused parameters and vet does not catch it.
// Adding coordinates back here would also reopen the privacy-label question the
// roadmap describes, since nothing in this DTO leaves the machine today.
// Series window bounds, in samples (the dish records one per second).
//
// The floor is the window every surface used before this was configurable, and
// the ceiling is the depth of the dish's own `dishGetHistory` ring — asking for
// more is not an error (LastN clamps), it just cannot return more, so naming
// the limit here keeps the app from offering a window the data can never fill.
const (
	defaultSeriesWindow = 60
	maxSeriesWindow     = 900
)

func clampSeriesWindow(w int) int {
	if w <= 0 {
		return defaultSeriesWindow
	}
	if w < defaultSeriesWindow {
		return defaultSeriesWindow
	}
	if w > maxSeriesWindow {
		return maxSeriesWindow
	}
	return w
}

// shortestSeries returns the length of the shortest non-empty series, or 0 if
// they are all empty. It is the span every one of them can honestly claim.
func shortestSeries(series ...[]float64) int {
	n := 0
	for _, s := range series {
		if len(s) == 0 {
			continue // an absent ring draws no row; it must not silence the rest
		}
		if n == 0 || len(s) < n {
			n = len(s)
		}
	}
	return n
}

func buildDashboard(s *dish.Status, h *dish.History, addr string, window int) Dashboard {
	d := Dashboard{
		SchemaVersion: DashboardSchemaVersion,
		State:         swiftState(derivedState(s)),
		SignalScore:   signalScore(s),
		UptimeHours:   float64(s.DeviceState.UptimeS) / 3600,
		Boots:         int(s.DeviceInfo.Bootcount),
		HardwareShort: hardwareShort(s.DeviceInfo.HardwareVersion),
		HardwareAim:   classifyHardware(s.DeviceInfo.HardwareVersion).Aim,
		DeviceID:      deviceID(s),
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
		w := clampSeriesWindow(window)
		d.PingSeries = h.LastN(h.PopPingLatencyMs, w)
		d.DownSeries = toMbps(h.LastN(h.DownlinkThroughputBps, w))
		d.UpSeries = toMbps(h.LastN(h.UplinkThroughputBps, w))
		d.PowerSeries = h.LastN(h.PowerIn, w)
		// What came back, not what was asked for — see SeriesSeconds. Taken
		// across every series the popover captions with it, not just ping:
		// `LastN` clamps each ring independently, so firmware that ships a
		// shorter `powerIn` than `popPingLatencyMs` would otherwise get a power
		// trace captioned with the ping window. Empty rings are skipped rather
		// than collapsing the figure to zero — an absent ring draws no row, and
		// hiding the other two with it would be a worse answer than a slightly
		// conservative one.
		d.SeriesSeconds = shortestSeries(d.PingSeries, d.DownSeries, d.PowerSeries)
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
		d.SessDegradedPct = round1(st.DegradedPct())
		d.SessDarkPct = round1(st.DarkPct())
		d.SessOutages = st.Outages()
		d.SessOutageSeconds = st.OutageSeconds
		d.SessLongestOutage = st.LongestOutage()
		d.SessDownPeak = round1(st.DownPeakMbps())
		d.SessUpPeak = round1(st.UpPeakMbps())
		d.SessDownBytes = st.DownBytes()
		d.SessUpBytes = st.UpBytes()
		d.SessPowerAvg = round1(st.PowerAvg())
		d.SessPowerPeak = round1(st.PowerMax)
		d.SessEnergyWh = round1(st.EnergyWh())
	}

	// Power-bank: only populated when an anchor is set (sl pb). With pb
	// disabled there is no anchor → onBattery=false, bankAnchored=false.
	if snap, _ := state.Load(); snap != nil {
		d.EnergyWhSinceBoot = round1(snap.EnergyWh)
		// Same predicates the CLI's Energy line uses, so the two surfaces
		// cannot describe the same accumulator differently.
		d.EnergyCoversBoot = snap.ObservedCoversBoot()
		if snap.ObsSeconds > 0 {
			d.EnergySeconds = snap.ObsSeconds
		}
		if avgW, ok := snap.ObservedAvgW(); ok {
			d.EnergyAvgW = round1(avgW)
		}
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
	// Observed samples, not wall clock — see Snapshot.ObservedAvgW. Getting
	// this wrong inflated time-to-empty by the ratio of elapsed time to
	// measured time, which on the power-bank use case is the single most
	// damaging number in the product.
	if avgW, ok := snap.ObservedAvgW(); ok && avgW > 0 {
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

// deviceID returns the dish's own identifier, falling back to the hardware
// version on firmware that doesn't report one. These were previously the same
// value: the DTO fed "deviceId" from HardwareVersion, so the app's device ID and
// its hardware label were one model string wearing two hats.
func deviceID(s *dish.Status) string {
	if s.DeviceInfo.Id != "" {
		return s.DeviceInfo.Id
	}
	return s.DeviceInfo.HardwareVersion
}

// Aim values for Dashboard.HardwareAim. The empty string is a real case and
// not a bug: a model this table has never heard of gets no claim at all, which
// the app renders as nothing. Telling someone with an unlisted dish to go turn
// it by hand is worse than staying quiet.
const (
	aimMotorized = "motorized"
	aimManual    = "manual"
	aimUnknown   = ""
)

// dishHardware is everything the `hardwareVersion` string says about the
// physical unit: a short display name, and whether the panel aims itself.
type dishHardware struct {
	Name string
	Aim  string
}

// classifyHardware reads the model out of a `deviceInfo.hardwareVersion`
// string ("rev3_proto2", "mini1_panda_prod1").
//
// Aim is inferred from the model rather than read from the dish, because the
// dish does not offer it: `dish_get_context` — the call that carries the
// actuator flag — is PermissionDenied to an unauthenticated caller, and
// `get_status` has no equivalent field. The inference is sound because the
// motors are a property of the model and nothing else: every rev1/rev2/rev3
// panel has them, no Gen3, Mini or flat High Performance panel does.
//
// Which is why the generation is now *in* the name. "Standard" covered both
// rev3 and rev4, and those are the two units that differ on exactly the
// question this function exists to answer — one aims itself, the other is
// aimed by hand — so the one label people read said nothing about the one
// thing that distinguishes them.
func classifyHardware(hw string) dishHardware {
	l := strings.ToLower(hw)
	switch {
	case strings.Contains(l, "mini"):
		return dishHardware{"Mini", aimManual}
	case strings.HasPrefix(l, "hp"):
		// Flat High Performance. Prefix, not substring: "hp" is two letters
		// and would otherwise match somewhere inside an unrelated model name.
		return dishHardware{"High Performance", aimManual}
	case strings.Contains(l, "rev1"):
		return dishHardware{"Round Gen1", aimMotorized}
	case strings.Contains(l, "rev2"), strings.Contains(l, "rev3"):
		// Both are the rectangular Gen2 panel on its motorized kickstand.
		return dishHardware{"Standard Gen2", aimMotorized}
	case strings.Contains(l, "rev4"):
		return dishHardware{"Standard Gen3", aimManual}
	case strings.Contains(l, "standard"):
		// A name that says "standard" and no generation. Gen2 and Gen3 are
		// both called that and only one has motors, so claim nothing.
		return dishHardware{"Standard", aimUnknown}
	case hw == "":
		return dishHardware{"?", aimUnknown}
	default:
		return dishHardware{hw, aimUnknown}
	}
}

func hardwareShort(hw string) string { return classifyHardware(hw).Name }

// hardwareNote is the gloss the CLI hangs off a raw model string:
// `rev3_proto2  (Standard Gen2, self-aiming)`. Empty when the model is one the
// table cannot place, so an unlisted dish keeps its raw string and gets no
// invented reading of it.
func hardwareNote(hw string) string {
	h := classifyHardware(hw)
	if h.Aim == aimUnknown {
		return ""
	}
	return fmt.Sprintf("  (%s, %s)", h.Name, aimPhrase(h.Aim))
}

// aimPhrase is how the CLI says an aim value. The app has its own wording; a
// terminal line and a 11-point label are not the same writing problem.
func aimPhrase(aim string) string {
	switch aim {
	case aimMotorized:
		return "self-aiming"
	case aimManual:
		return "aim by hand"
	default:
		return ""
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
