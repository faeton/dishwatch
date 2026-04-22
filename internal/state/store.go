// Package state persists dish snapshots and an event log to disk.
//
// File layout (identical to the bash version so the two implementations share
// state during the transition):
//
//	~/.cache/sl/state.json  — last snapshot
//	~/.cache/sl/events.log  — append-only "YYYY-MM-DD HH:MM:SS  TAG  msg"
//	~/.cache/sl/pb.json     — power-bank anchor (see internal/pb)
//	~/.cache/sl/geo_*.txt   — reverse-geocode cache (see internal/geo)
package state

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	eventsCap  = 2000 // rotate when file grows past this many lines
	eventsKeep = 1500 // …to this many on rotation
)

// Snapshot mirrors the bash state.json schema. Booleans are stored as strings
// ("true"/"false") to match jq's @sh output and keep the two implementations
// binary-compatible on disk.
type Snapshot struct {
	TS             int64   `json:"ts"`
	Boots          int     `json:"boots"`
	UptimeS        int64   `json:"uptimeS"`
	State          string  `json:"state"`
	Disable        string  `json:"disable"`
	Alerts         string  `json:"alerts"`
	ReadyAll       string  `json:"ready_all"` // "true"/"false"
	Ping           float64 `json:"ping"`
	Drop           float64 `json:"drop"`
	EnergyWh       float64 `json:"energyWh"`
	LastCurrent    int64   `json:"lastCurrent"`
	ObsStartTs     int64   `json:"obsStartTs"`
	ObsStartUptime int64   `json:"obsStartUptime"`
}

// CacheDir returns ~/.cache/sl, creating it if missing.
func CacheDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(home, ".cache", "sl")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}

func statePath() (string, error) {
	d, err := CacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "state.json"), nil
}

func eventsPath() (string, error) {
	d, err := CacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, "events.log"), nil
}

// Load reads the last snapshot. Returns (nil, nil) if none exists.
func Load() (*Snapshot, error) {
	p, err := statePath()
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
	var s Snapshot
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, fmt.Errorf("parse state: %w", err)
	}
	return &s, nil
}

// Save writes the snapshot atomically (temp + rename).
func Save(s *Snapshot) error {
	p, err := statePath()
	if err != nil {
		return err
	}
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

// LogEvent appends one line to events.log and rotates if it grows too large.
// Format matches the bash _sl_log: "2006-01-02 15:04:05  TAG        message".
func LogEvent(tag, msg string) error {
	p, err := eventsPath()
	if err != nil {
		return err
	}
	f, err := os.OpenFile(p, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	line := fmt.Sprintf("%s  %-10s %s\n", time.Now().Format("2006-01-02 15:04:05"), tag, msg)
	if _, err := f.WriteString(line); err != nil {
		return err
	}
	// Line-count based rotation — cheap check via file size proxy + occasional
	// accurate count. We just count every call; files this size are <200 KB.
	if n, _ := countLines(p); n > eventsCap {
		_ = rotateEvents(p, eventsKeep)
	}
	return nil
}

// TailEvents returns the last n lines (oldest→newest).
func TailEvents(n int) ([]string, error) {
	p, err := eventsPath()
	if err != nil {
		return nil, err
	}
	f, err := os.Open(p)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()
	var lines []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if len(lines) <= n {
		return lines, nil
	}
	return lines[len(lines)-n:], nil
}

// DiffAndLog compares prev→cur and writes transition events. Accepts nil prev
// (first-run: emits SESSION).
func DiffAndLog(cur *Snapshot, prev *Snapshot) error {
	if prev == nil {
		return LogEvent("SESSION", fmt.Sprintf("first snapshot — boots=%d uptime=%ds", cur.Boots, cur.UptimeS))
	}
	gap := cur.TS - prev.TS
	rebooted := cur.Boots != prev.Boots
	if rebooted {
		_ = LogEvent("REBOOT", fmt.Sprintf("dish rebooted (boots %d→%d)", prev.Boots, cur.Boots))
	} else if cur.UptimeS < prev.UptimeS {
		_ = LogEvent("REBOOT", fmt.Sprintf("dish uptime reset (%d→%ds, same bootcount %d)", prev.UptimeS, cur.UptimeS, cur.Boots))
	}
	if gap > 30 {
		human := HumanDur(gap)
		if rebooted {
			_ = LogEvent("GAP", fmt.Sprintf("%s unseen — dish rebooted during gap", human))
		} else {
			_ = LogEvent("GAP", fmt.Sprintf("%s unseen — dish stayed up (local/Wi-Fi side)", human))
		}
	}
	if cur.State != prev.State {
		_ = LogEvent("STATE", fmt.Sprintf("%s → %s", prev.State, cur.State))
	}
	if cur.Disable != prev.Disable {
		_ = LogEvent("SERVICE", fmt.Sprintf("%s → %s", prev.Disable, cur.Disable))
	}
	if cur.ReadyAll != prev.ReadyAll {
		_ = LogEvent("READY", fmt.Sprintf("all-ready %s → %s", prev.ReadyAll, cur.ReadyAll))
	}
	if cur.Alerts != prev.Alerts {
		_ = LogEvent("ALERTS", fmt.Sprintf("%s → %s", prev.Alerts, cur.Alerts))
	}
	return nil
}

// MarkUnreachable appends an UNREACH line, rate-limited to once per minute so
// a wedged watch loop doesn't spam the file.
func MarkUnreachable(addr string) error {
	lines, _ := TailEvents(20)
	cutoff := time.Now().Add(-time.Minute)
	for i := len(lines) - 1; i >= 0; i-- {
		if !strings.Contains(lines[i], "  UNREACH    ") {
			continue
		}
		// Parse timestamp from the first 19 chars
		if len(lines[i]) < 19 {
			continue
		}
		ts, err := time.ParseInLocation("2006-01-02 15:04:05", lines[i][:19], time.Local)
		if err != nil {
			continue
		}
		if ts.After(cutoff) {
			return nil // already logged recently
		}
		break
	}
	return LogEvent("UNREACH", fmt.Sprintf("dish/api not answering (%s)", addr))
}

// HumanDur is the Go equivalent of the bash _sl_humanize_dur helper.
func HumanDur(sec int64) string {
	if sec < 0 {
		sec = 0
	}
	d := sec / 86400
	sec %= 86400
	h := sec / 3600
	sec %= 3600
	m := sec / 60
	s := sec % 60
	var b strings.Builder
	if d > 0 {
		fmt.Fprintf(&b, "%dd ", d)
	}
	if h > 0 || b.Len() > 0 {
		fmt.Fprintf(&b, "%dh ", h)
	}
	if m > 0 || b.Len() > 0 {
		fmt.Fprintf(&b, "%dm ", m)
	}
	fmt.Fprintf(&b, "%ds", s)
	return b.String()
}

// ----- internals -----

func countLines(path string) (int, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	n := 0
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		n++
	}
	return n, sc.Err()
}

func rotateEvents(path string, keep int) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	var lines []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	if len(lines) <= keep {
		return nil
	}
	tail := lines[len(lines)-keep:]
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(strings.Join(tail, "\n")+"\n"), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
