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

	// UptimeSlackS is how far uptime may go backwards before we call it a
	// reboot. A reboot resets uptime to roughly zero, so it clears any slack we
	// allow here by a wide margin — while a single rounded-down report from the
	// dish used to wipe every accumulator irrecoverably, because the test was a
	// bare `uptime < prevUptime`. Bootcount remains the primary detector; this
	// is only the fallback for a reboot the counter missed.
	UptimeSlackS int64 = 5

	// ObsSecondsUnknown marks an epoch whose energy total predates the sample
	// counter, so no honest average can be derived from it. See Snapshot.
	ObsSecondsUnknown int64 = -1
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
	// ObsSeconds counts powerIn samples actually integrated into EnergyWh this
	// boot. It is the denominator for the average — wall clock is not, because
	// a gap wider than the ring advances the cursor without contributing any
	// energy, so `now - ObsStartTs` grows while EnergyWh does not. Stats has
	// always used its own Samples counter for exactly this reason (stats.go);
	// energy went without one and collapsed its average across any gap.
	//
	// Three states, and the third one matters:
	//
	//	> 0   a real count; EnergyWh divided by it is the observed mean
	//	  0   nothing integrated yet
	//	 -1   UNKNOWN — a total exists but was accumulated before this field did
	//
	// The unknown case is the migration. A snapshot written by an older build
	// (or by a bash `sl` predating the field) carries a real EnergyWh and no
	// count. Leaving it at 0 and letting the next poll increment normally is
	// worse than useless: the numerator keeps hours of accumulated energy while
	// the denominator restarts from a handful of new seconds, so the first poll
	// after upgrading reports something like 5000 W. Once unknown, the epoch
	// stays unknown and no average is offered until the next reboot resets it.
	ObsSeconds int64 `json:"obsSeconds"`
}

// IsRestart reports whether uptime going from prev to now means the dish
// restarted, for the case where the bootcount did not change.
//
// Two rules, because one is not enough at either end. The slack absorbs a
// rounded-down report — a bare `now < prev` used to treat one second of jitter
// as a reboot and wipe every accumulator irrecoverably. The halving rule
// catches the other end: a dish that reboots after five seconds of uptime drops
// to zero, which the slack alone would swallow.
func IsRestart(now, prev int64) bool {
	if prev < 0 {
		return false
	}
	return now < prev-UptimeSlackS || now*2 < prev
}

// ObservedAvgW returns the mean power across the samples actually integrated
// into EnergyWh, and whether it could be computed at all.
//
// The denominator is ObsSeconds, never wall clock. Dividing by
// `now - ObsStartTs` was wrong in a way that got *more* confident the worse it
// got: a gap wider than the ring contributes no energy but plenty of elapsed
// time, so a 20 W dish left unwatched for nine hours reported "avg 0.4 W", and
// because the elapsed window had by then grown to roughly the uptime it also
// satisfied the coverage test below and printed as a plain "since boot" figure
// rather than an explicitly partial one.
//
// The false return is for snapshots written before ObsSeconds existed (or by
// the bash `sl` if it ever drops the field). There is no honest average to give
// for those, so callers must omit it rather than invent a denominator.
func (s *Snapshot) ObservedAvgW() (float64, bool) {
	if s == nil || s.ObsSeconds < 1 || s.EnergyWh <= 0 {
		return 0, false // includes ObsSecondsUnknown
	}
	return s.EnergyWh * 3600 / float64(s.ObsSeconds), true
}

// ObservedCoversBoot reports whether the samples we hold account for
// essentially the whole uptime, which is what lets the CLI say "since boot"
// instead of quoting an observation window and an extrapolation.
func (s *Snapshot) ObservedCoversBoot() bool {
	return s != nil && s.ObsSeconds > 0 && s.ObsSeconds*100 >= s.UptimeS*95
}

// dirOverride, when non-empty, replaces the default cache location. It exists
// so tests can point at a temp dir, and so a sandboxed host (the macOS app,
// which cannot reach ~/.cache) can supply its own container path without this
// package having to know anything about it.
//
// The default stays ~/.cache/sl rather than os.UserCacheDir() on purpose: the
// bash `sl` hardcodes that path, and moving it silently would orphan existing
// users' energy history. See docs/roadmap.md for the migration.
var dirOverride string

// SetDir overrides the cache directory for the life of the process. Pass "" to
// restore the default.
func SetDir(d string) { dirOverride = d }

// CacheDir returns the storage directory, creating it if missing.
func CacheDir() (string, error) {
	dir := dirOverride
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		dir = filepath.Join(home, ".cache", "sl")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}

// writeFileAtomic replaces path with data via a uniquely-named temp file in the
// same directory.
//
// A fixed "<path>.tmp" name is not safe under concurrency even though the
// rename itself is atomic: two processes writing at once open the *same* temp
// path and interleave their bytes, so whichever renames second can publish a
// blend of both. The transaction lock in lock.go makes that unreachable for Go
// callers, but a unique name means a stray concurrent writer corrupts only its
// own temp file rather than the file we are about to publish.
// WriteFileAtomic is writeFileAtomic for callers outside this package that
// store their own files in the cache directory — the power-bank anchor, today.
// Exported rather than duplicated so there is one place where "publish a file"
// is defined, and so the next such file cannot quietly reintroduce the fixed
// temp name.
func WriteFileAtomic(path string, data []byte, perm os.FileMode) error {
	return writeFileAtomic(path, data, perm)
}

func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	f, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp) // no-op once the rename succeeds
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Chmod(perm); err != nil {
		f.Close()
		return err
	}
	// Durability, not just atomicity. Rename is atomic with respect to other
	// processes, but without an fsync the bytes may still be in the page cache
	// when the machine loses power — and this tool's audience runs dishes off
	// batteries in vehicles, where an abrupt cut is the normal shutdown. An
	// unflushed state.json comes back truncated or garbage, Load treats that as
	// "no prior snapshot", and the energy total silently restarts from the ring.
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	// Sync the directory too, or the rename itself can be lost while the file
	// contents survive. Best-effort: some filesystems refuse to open a
	// directory for sync, and a failure here is not worth failing the write.
	if d, err := os.Open(filepath.Dir(path)); err == nil {
		_ = d.Sync()
		d.Close()
	}
	return nil
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
	return writeFileAtomic(p, b, 0o644)
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
	return writeFileAtomic(path, []byte(strings.Join(tail, "\n")+"\n"), 0o644)
}
