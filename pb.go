package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/faeton/dishwatch/internal/state"
	"github.com/faeton/dishwatch/internal/ui"
)

// Anchor represents a point-in-time power-bank reading. When set, the dash
// shows depletion counted directly from integrated Wh since the anchor — no
// extrapolation. If the anchor's bootcount doesn't match the current boot,
// it's considered stale and ignored.
type Anchor struct {
	Pct      float64 `json:"pct"`
	Wh       float64 `json:"wh,omitempty"`       // full-charge Wh, optional
	EnergyWh float64 `json:"energyWh,omitempty"` // integrated Wh at anchor time
	Uptime   int64   `json:"uptime,omitempty"`
	Boots    int     `json:"boots,omitempty"`
	TS       int64   `json:"ts,omitempty"`
}

func anchorPath() (string, error) {
	d, err := state.CacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "pb.json"), nil
}

func loadAnchor() (*Anchor, error) {
	p, err := anchorPath()
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	if len(b) == 0 {
		return nil, nil
	}
	var a Anchor
	if err := json.Unmarshal(b, &a); err != nil {
		return nil, err
	}
	return &a, nil
}

func saveAnchor(a *Anchor) error {
	p, err := anchorPath()
	if err != nil {
		return err
	}
	b, err := json.Marshal(a)
	if err != nil {
		return err
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

func deleteAnchor() error {
	p, err := anchorPath()
	if err != nil {
		return err
	}
	return os.Remove(p)
}

// runPb implements the `sl pb` subcommand.
//
//	sl pb                      show current anchor
//	sl pb <pct> [wh]           anchor bank % now (and optional full-charge Wh)
//	sl pb -                    clear the anchor (alias: reset, clear, off)
func runPb(ctx context.Context, args []string) error {
	if len(args) == 0 {
		a, err := loadAnchor()
		if err != nil {
			return err
		}
		if a == nil {
			fmt.Println("no anchor set.")
			pbHelp(os.Stderr)
			return nil
		}
		age := time.Now().Unix() - a.TS
		whStr := "—"
		if a.Wh > 0 {
			whStr = fmt.Sprintf("%.1f", a.Wh)
		}
		fmt.Printf("anchor: %.1f%% · bank=%s Wh · set %s ago (at dish uptime %ds, boots=%d, energyWh=%.2f)\n",
			a.Pct, whStr, state.HumanDur(age), a.Uptime, a.Boots, a.EnergyWh)
		return nil
	}

	switch args[0] {
	case "-", "reset", "clear", "off":
		if err := deleteAnchor(); err != nil {
			if os.IsNotExist(err) {
				fmt.Println("no anchor to clear.")
				return nil
			}
			return err
		}
		fmt.Println("anchor cleared.")
		return nil
	case "-h", "--help", "help":
		pbHelp(os.Stdout)
		return nil
	}

	pct, err := strconv.ParseFloat(args[0], 64)
	if err != nil || pct < 0 || pct > 100 {
		pbHelp(os.Stderr)
		return fmt.Errorf("invalid pct: %q", args[0])
	}
	var wh float64
	if len(args) >= 2 {
		wh, err = strconv.ParseFloat(args[1], 64)
		if err != nil || wh <= 0 {
			pbHelp(os.Stderr)
			return fmt.Errorf("invalid wh: %q", args[1])
		}
	}

	// Refresh state by running a dash pass silently so we have the latest
	// energy accumulator to anchor against.
	if err := runDashSilent(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "warning: could not refresh state before anchor:", err)
	}
	snap, err := state.Load()
	if err != nil || snap == nil {
		return fmt.Errorf("no state yet — is the dish reachable?")
	}

	// If wh not given this time, preserve the prior wh from the existing
	// anchor (matches bash).
	if wh == 0 {
		if prev, _ := loadAnchor(); prev != nil {
			wh = prev.Wh
		}
	}

	a := &Anchor{
		Pct:      pct,
		Wh:       wh,
		EnergyWh: snap.EnergyWh,
		Uptime:   snap.UptimeS,
		Boots:    snap.Boots,
		TS:       time.Now().Unix(),
	}
	if err := saveAnchor(a); err != nil {
		return err
	}
	whStr := "—"
	if a.Wh > 0 {
		whStr = fmt.Sprintf("%.1f", a.Wh)
	}
	fmt.Printf("anchored: %.1f%% · bank=%s Wh (uptime %ds, energyWh=%.2f, boots=%d)\n",
		a.Pct, whStr, a.Uptime, a.EnergyWh, a.Boots)
	return nil
}

func pbHelp(w io.Writer) {
	fmt.Fprintln(w, "usage:")
	fmt.Fprintln(w, "  sl pb                      show current anchor")
	fmt.Fprintln(w, "  sl pb <pct> [wh]           anchor bank % now (and optional full-charge Wh)")
	fmt.Fprintln(w, "  sl pb -                    clear the anchor (alias: reset, clear, off)")
}

// runDashSilent runs the full dash fetch+snapshot pipeline but discards all
// rendered output. Used by `sl pb` to ensure the energy accumulator is up to
// date before writing the anchor.
func runDashSilent(ctx context.Context) error {
	c, err := dialDish(ctx)
	if err != nil {
		return err
	}
	defer c.Close()
	_, _, err = fetchDash(ctx, c)
	return err
}

// ---- dash integration ----

// pbRenderBank is the implementation installed into the renderBank indirection
// defined in dash.go. Runs as part of the Energy section.
func pbRenderBank(w io.Writer, L ui.Layout, snap *state.Snapshot, avgW float64) {
	a, _ := loadAnchor()
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
		// over the full uptime from the observation window.
		now := time.Now().Unix()
		obsDur := now - snap.ObsStartTs
		if obsDur < 1 {
			obsDur = 1
		}
		usedWh = snap.EnergyWh * float64(snap.UptimeS) / float64(obsDur)
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
