package state

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// The ladder, end to end. Each row is the boundary or the shape it names, so a
// change to the collapse rule fails here rather than in a screenshot.
func TestUptimeDur(t *testing.T) {
	const (
		min  = 60
		hour = 60 * min
		day  = 24 * hour
	)
	cases := []struct {
		sec  int64
		want string
	}{
		{-5, "0s"}, // clamped, not "-5s"
		{0, "0s"},  // just booted — the case "0.0h" could not tell apart
		{45, "45s"},
		{59, "59s"},
		{60, "1m"},      // seconds never pair with minutes
		{6 * min, "6m"}, // the old line called this "0.1 h"
		{59 * min, "59m"},
		{hour, "1h"}, // zero minor unit dropped
		{hour + 5*min, "1h5m"},
		{9*hour + 59*min, "9h59m"},
		{10 * hour, "10h"}, // double-digit major: minor unit drops
		{13*hour + 42*min, "13h"},
		{23*hour + 59*min, "23h"},
		{day, "1d"},
		{3*day + 4*hour, "3d4h"},
		{9*day + 23*hour, "9d23h"},
		{10*day + 5*hour, "10d"},
		{24 * day, "24d"},
		{29*day + 23*hour, "29d"},
		{30 * day, "1mo"},
		{44 * day, "1mo14d"},
		{300 * day, "10mo"}, // 10 months: minor drops again
		{365 * day, "1y"},
		{400 * day, "1y1mo"},
	}
	for _, c := range cases {
		if got := UptimeDur(c.sec); got != c.want {
			t.Errorf("UptimeDur(%d) = %q, want %q", c.sec, got, c.want)
		}
	}
}

// HumanDur is a different shape on purpose — a log line spells every unit out.
// If someone collapses the two, this fails.
func TestUptimeDurIsNotHumanDur(t *testing.T) {
	const sec = 3*86400 + 4*3600 + 12*60 + 30
	if UptimeDur(sec) == HumanDur(sec) {
		t.Fatalf("UptimeDur and HumanDur should differ: both %q", UptimeDur(sec))
	}
	if got, want := UptimeDur(sec), "3d4h"; got != want {
		t.Errorf("UptimeDur = %q, want %q", got, want)
	}
}

// The same ladder, against the file bash and jq are also held to. TestUptimeDur
// above is the readable spec — this one exists for a different reason: `sl` and
// its jq status filter each carry their own copy of this rule, and nothing in
// `go test` can see them. testdata/uptime-ladder.txt is the shared reference,
// and scripts/check-uptime-parity.sh holds the other two to it.
func TestUptimeDurGolden(t *testing.T) {
	f, err := os.Open(filepath.Join("testdata", "uptime-ladder.txt"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	n := 0
	sc := bufio.NewScanner(f)
	for line := 1; sc.Scan(); line++ {
		text := strings.TrimSpace(sc.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		fields := strings.Fields(text)
		if len(fields) != 2 {
			t.Fatalf("line %d: want '<seconds> <want>', got %q", line, text)
		}
		sec, err := strconv.ParseInt(fields[0], 10, 64)
		if err != nil {
			t.Fatalf("line %d: %v", line, err)
		}
		if got := UptimeDur(sec); got != fields[1] {
			t.Errorf("line %d: UptimeDur(%d) = %q, want %q", line, sec, got, fields[1])
		}
		n++
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	// A golden file that silently reads as empty asserts nothing, which is the
	// one failure mode this whole arrangement is meant to rule out.
	if n < 20 {
		t.Fatalf("golden file has only %d cases — is it truncated?", n)
	}
}
