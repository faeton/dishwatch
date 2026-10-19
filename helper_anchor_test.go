package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/faeton/dishwatch/internal/state"
)

// The app's "Stop tracking" goes through this op, and it has to end in the
// state the dashboard reads as mains: no pb.json. Clearing when nothing is
// anchored must also succeed — the app asked for "not tracking", and got it.
func TestHelperClearAnchor(t *testing.T) {
	dir := t.TempDir()
	state.SetDir(dir)
	t.Cleanup(func() { state.SetDir("") })

	anchor := filepath.Join(dir, "pb.json")
	if err := os.WriteFile(anchor, []byte(`{"pct":80,"wh":67}`), 0o644); err != nil {
		t.Fatal(err)
	}

	for i, want := range []string{"cleared", "already clear"} {
		var out bytes.Buffer
		h := &helper{out: json.NewEncoder(&out)}
		h.serve(context.Background(), helperRequest{ID: int64(i), Op: "clearAnchor"})

		var resp helperResponse
		if err := json.Unmarshal(out.Bytes(), &resp); err != nil {
			t.Fatalf("%s: bad reply %q: %v", want, out.String(), err)
		}
		if !resp.OK || resp.Error != "" {
			t.Fatalf("%s: got ok=%v error=%q", want, resp.OK, resp.Error)
		}
		if _, err := os.Stat(anchor); !os.IsNotExist(err) {
			t.Fatalf("%s: anchor still present (stat err %v)", want, err)
		}
	}
}

// Calibrate divides bankUsedWh by the drop from bankAnchorPct. Both have to be
// the anchor's own figures, not ones derived from the capacity being solved.
func TestFillBankReportsAnchorAndUsedWh(t *testing.T) {
	dir := t.TempDir()
	state.SetDir(dir)
	t.Cleanup(func() { state.SetDir("") })

	if err := os.WriteFile(filepath.Join(dir, "pb.json"),
		[]byte(`{"pct":90,"wh":67,"energyWh":10,"boots":4}`), 0o644); err != nil {
		t.Fatal(err)
	}
	var d Dashboard
	fillBank(&d, &state.Snapshot{EnergyWh: 17.37, Boots: 4})

	if d.BankAnchorPct != 90 {
		t.Errorf("bankAnchorPct = %v, want 90", d.BankAnchorPct)
	}
	if d.BankUsedWh != 7.37 {
		t.Errorf("bankUsedWh = %v, want 7.37", d.BankUsedWh)
	}
	// The README's worked example: 7.37 Wh over an 11% drop → 67 Wh.
	if got := d.BankUsedWh / ((d.BankAnchorPct - 79) / 100); got < 66.5 || got > 67.5 {
		t.Errorf("calibration from these fields = %.1f Wh, want ~67", got)
	}
}
