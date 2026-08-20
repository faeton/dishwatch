//go:build !apphelper

package main

// The power-bank line, drawn into the CLI's Energy section.
//
// Split from pb.go so the embedded helper does not carry it. The anchor logic
// next door *is* engine — the app's `setAnchor` op calls straight into it — but
// this half is terminal rendering, and it was the one thing keeping the CLI's
// render path alive inside the bundled binary after the command table was
// split. `renderBank` is a package-level func var assigned from `init()`, and
// an `init()` always runs, so the linker could never prove `pbRenderBank`
// unreachable however dead its only caller became. Under `apphelper` the var
// keeps the no-op default declared in dash.go, which nothing calls anyway.

import (
	"fmt"
	"io"
	"math"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/faeton/dishwatch/internal/state"
	"github.com/faeton/dishwatch/internal/ui"
)

// ---- dash integration ----

// pbRenderBank is the implementation installed into the renderBank indirection
// defined in dash.go. Runs as part of the Energy section.
func pbRenderBank(w io.Writer, L ui.Layout, pv persisted, avgW float64) {
	snap, a := pv.snap, pv.anchor
	if snap == nil {
		return
	}
	envWh, _ := strconv.ParseFloat(os.Getenv("SL_PB_WH"), 64)
	envStartPct := 100.0
	if v, err := strconv.ParseFloat(os.Getenv("SL_PB_START_PCT"), 64); err == nil && v > 0 {
		envStartPct = v
	}

	// Effective bank capacity: anchor.Wh wins, else SL_PB_WH. If neither,
	// we can't render depletion.
	var cap float64
	switch {
	case a != nil && a.Wh > 0:
		cap = a.Wh
	case envWh > 0:
		cap = envWh
	default:
		return
	}

	var pctLeft, usedWh float64
	var source string
	if a != nil && a.Boots == snap.Boots && a.Wh > 0 {
		usedWh = snap.EnergyWh - a.EnergyWh
		if usedWh < 0 {
			usedWh = 0
		}
		pctLeft = a.Pct - usedWh*100/cap
		age := time.Now().Unix() - a.TS
		source = fmt.Sprintf("anchor %.1f%% set %s ago", a.Pct, state.HumanDur(age))
	} else {
		// Extrapolate from boot: assume full at boot, estimate total burn
		// over the full uptime from the observation window. The window is the
		// count of samples we integrated, not elapsed wall clock — scaling by
		// elapsed time understates the burn by however long we were not
		// watching, which reads as a fuller bank than there is.
		if snap.ObsSeconds < 1 {
			return // no honest observation window to extrapolate from
		}
		usedWh = snap.EnergyWh * float64(snap.UptimeS) / float64(snap.ObsSeconds)
		pctLeft = envStartPct - usedWh*100/cap
		source = fmt.Sprintf("assuming %.0f%% at boot · set via: sl pb <current%%> [bank_wh]", envStartPct)
	}

	whLeft := cap * pctLeft / 100
	if whLeft < 0 {
		whLeft = 0
	}
	var secLeft float64
	if avgW > 0 {
		secLeft = whLeft * 3600 / avgW
		if secLeft < 0 {
			secLeft = 0
		}
	}

	col := ui.OK
	if pctLeft < 50 {
		col = ui.Warn
	}
	if pctLeft < 20 {
		col = ui.Err
	}
	barPct := int(math.Round(pctLeft))
	if barPct < 0 {
		barPct = 0
	}
	if barPct > 100 {
		barPct = 100
	}
	leftStr := state.HumanDur(int64(secLeft))

	fmt.Fprintf(w, "  %sBank  %s %s  %s%.1f%%%s left · %.1f Wh · %sdies in %s%s\n",
		ui.Lbl, ui.Rst, ui.Bar(barPct, L.BarW, col),
		col, pctLeft, ui.Rst, whLeft, ui.Val, leftStr, ui.Rst)
	fmt.Fprintf(w, "        %s%s · bank=%.1f Wh%s\n",
		ui.Dim, source, cap, ui.Rst)
	_ = strings.TrimSpace
}

func init() { renderBank = pbRenderBank }
