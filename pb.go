package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/faeton/dishwatch/internal/state"
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
	// Was a fixed "<path>.tmp", which is the same trap fixed in state.Save and
	// in the bash `sl`: the rename is atomic, but two writers open the *same*
	// scratch path and interleave their bytes before either renames.
	return state.WriteFileAtomic(p, b, 0o644)
}

// setAnchor pins a bank percentage to the energy total as it stands right now,
// and is the single writer of the anchor for both the CLI and the helper.
//
// The whole thing runs under the state lock, not just the save. The anchor is
// only meaningful as a *pair* — this percentage at that energyWh — so a poll
// landing between the read and the write leaves every later runtime estimate
// off by the delta, permanently and invisibly. Reading the previous capacity
// has to be inside too: `wh == nil` means "keep what was there", and a
// concurrent `pb` swapping capacity underneath us would otherwise get the old
// figure republished against the new percentage.
//
// Deliberately does not refresh state itself. The CLI polls immediately before
// calling; the helper polls on its own cadence and would only be re-entering
// its own transaction.
func setAnchor(pct float64, wh *float64) (*Anchor, error) {
	if pct < 0 || pct > 100 {
		return nil, fmt.Errorf("invalid pct: %v", pct)
	}
	if wh != nil && *wh <= 0 {
		return nil, fmt.Errorf("invalid wh: %v", *wh)
	}

	txn, _ := state.Begin()
	defer txn.Close()

	snap, err := state.Load()
	if err != nil || snap == nil {
		return nil, fmt.Errorf("no state yet — is the dish reachable?")
	}

	a := &Anchor{
		Pct:      pct,
		EnergyWh: snap.EnergyWh,
		Uptime:   snap.UptimeS,
		Boots:    snap.Boots,
		TS:       time.Now().Unix(),
	}
	if wh != nil {
		a.Wh = *wh
	} else if prev, _ := loadAnchor(); prev != nil {
		a.Wh = prev.Wh
	}
	if err := saveAnchor(a); err != nil {
		return nil, err
	}
	return a, nil
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
	//
	// This must be fatal, not a warning. An anchor is only meaningful as a
	// (pct, energyWh) pair: it means "the bank was at this percentage when the
	// dish had drawn this many Wh". Pinning a fresh percentage to a stale
	// energyWh silently biases every depletion estimate for the life of the
	// anchor, which is exactly what setAnchor's own comment below warns about —
	// warning and carrying on reintroduced it one level up.
	if err := runDashSilent(ctx); err != nil {
		return fmt.Errorf("cannot anchor against stale state: %w", err)
	}
	snap, err := state.Load()
	if err != nil || snap == nil {
		return fmt.Errorf("no state yet — is the dish reachable?")
	}

	var whp *float64
	if wh > 0 {
		whp = &wh
	}
	a, err := setAnchor(pct, whp)
	if err != nil {
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
