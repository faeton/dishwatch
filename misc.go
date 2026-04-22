package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"

	"github.com/faeton/dishwatch/internal/ui"
)

// runHistory prints a small summary over the full 15-min ring buffer.
func runHistory(ctx context.Context) error {
	c, err := dialDish(ctx)
	if err != nil {
		return err
	}
	defer c.Close()
	h, err := c.GetHistory(ctx)
	if err != nil {
		return err
	}
	summary := map[string]any{
		"samples":              len(h.PopPingLatencyMs),
		"popPingLatencyMsMean": nonzeroMean(h.PopPingLatencyMs),
		"popPingDropRateMean":  mean(h.PopPingDropRate),
		"downlinkMbpsMean":     mean(h.DownlinkThroughputBps) / 1e6,
		"uplinkMbpsMean":       mean(h.UplinkThroughputBps) / 1e6,
	}
	b, err := json.MarshalIndent(summary, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(b))
	return nil
}

// runMap prints the dimensions of the obstruction map.
func runMap(ctx context.Context) error {
	c, err := dialDish(ctx)
	if err != nil {
		return err
	}
	defer c.Close()
	raw, err := c.Call(ctx, []byte(`{"dish_get_obstruction_map":{}}`))
	if err != nil {
		return err
	}
	var wrap struct {
		M struct {
			NumRows int       `json:"numRows"`
			NumCols int       `json:"numCols"`
			Snr     []float64 `json:"snr"`
		} `json:"dishGetObstructionMap"`
	}
	if err := json.Unmarshal(raw, &wrap); err != nil {
		return err
	}
	out, _ := json.MarshalIndent(map[string]int{
		"numRows":  wrap.M.NumRows,
		"numCols":  wrap.M.NumCols,
		"snrCells": len(wrap.M.Snr),
	}, "", "  ")
	fmt.Println(string(out))
	return nil
}

// runReboot sends the reboot command.
func runReboot(ctx context.Context) error {
	c, err := dialDish(ctx)
	if err != nil {
		return err
	}
	defer c.Close()
	raw, err := c.Call(ctx, []byte(`{"reboot":{}}`))
	if err != nil {
		return err
	}
	var pretty bytes.Buffer
	if json.Indent(&pretty, raw, "", "  ") == nil {
		fmt.Println(pretty.String())
	} else {
		fmt.Println(string(raw))
	}
	return nil
}

// runRaw sends an arbitrary JSON request and prints the pretty response.
// Default request is {"get_status":{}} to match the bash fallback.
func runRaw(ctx context.Context, reqJSON string) error {
	if reqJSON == "" {
		reqJSON = `{"get_status":{}}`
	}
	c, err := dialDish(ctx)
	if err != nil {
		return err
	}
	defer c.Close()
	raw, err := c.Call(ctx, []byte(reqJSON))
	if err != nil {
		return err
	}
	var pretty bytes.Buffer
	if json.Indent(&pretty, raw, "", "  ") == nil {
		fmt.Println(pretty.String())
	} else {
		fmt.Println(string(raw))
	}
	return nil
}

// runSpeed does a Mac-side speedtest: LAN ping to the dish + macOS
// `networkQuality`. The dish-side speedtest RPC needs auth we can't do from
// an unauthenticated CLI.
func runSpeed(ctx context.Context) error {
	fmt.Printf("%sStarlink speed test (Mac-side — dish-side API requires auth we can't do from shell)%s\n\n",
		ui.Hdr, ui.Rst)

	fmt.Printf("%s[1/2] LAN RTT to dish (192.168.100.1)%s\n", ui.Hdr, ui.Rst)
	out, err := exec.CommandContext(ctx, "ping", "-c", "10", "-q", "-i", "0.2", "-W", "1000", "192.168.100.1").CombinedOutput()
	if err != nil {
		fmt.Printf("      %sping failed: %v%s\n\n", ui.Err, err, ui.Rst)
	} else {
		avg := pingAvg(out)
		loss := pingLoss(out)
		fmt.Printf("      %savg %s ms · loss %s%s\n\n", ui.Val, nz(avg, "?"), nz(loss, "?"), ui.Rst)
	}

	fmt.Printf("%s[2/2] Internet speed (via dish → PoP → Apple test servers)%s\n", ui.Hdr, ui.Rst)
	if _, err := exec.LookPath("networkQuality"); err != nil {
		fmt.Printf("      %snetworkQuality not available (macOS 12+ required)%s\n", ui.Dim, ui.Rst)
	} else {
		cmd := exec.CommandContext(ctx, "networkQuality", "-v")
		cmd.Stdout = &lineFilter{prefix: "      "}
		cmd.Stderr = os.Stderr
		_ = cmd.Run()
	}
	fmt.Printf("\n%sNote: dish↔PoP speedtest needs auth and isn't reachable from unauthenticated CLI.%s\n",
		ui.Dim, ui.Rst)
	return nil
}

// ---- helpers ----

var pingAvgRE = regexp.MustCompile(`min/avg/max/\w* = [\d.]+/([\d.]+)/`)
var pingLossRE = regexp.MustCompile(`(\d+(?:\.\d+)?%) packet loss`)

func pingAvg(out []byte) string {
	if m := pingAvgRE.FindSubmatch(out); len(m) == 2 {
		return string(m[1])
	}
	return ""
}

func pingLoss(out []byte) string {
	if m := pingLossRE.FindSubmatch(out); len(m) == 2 {
		return string(m[1])
	}
	return ""
}

func nz(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

func nonzeroMean(vs []float64) float64 {
	var s float64
	var n int
	for _, v := range vs {
		if v > 0 {
			s += v
			n++
		}
	}
	if n == 0 {
		return 0
	}
	return s / float64(n)
}

// lineFilter wraps an io.Writer to prefix every output line. Used so
// networkQuality's output lines up with the speedtest header indent.
type lineFilter struct {
	prefix string
	buf    []byte
}

func (f *lineFilter) Write(p []byte) (int, error) {
	f.buf = append(f.buf, p...)
	for {
		i := bytes.IndexByte(f.buf, '\n')
		if i < 0 {
			break
		}
		line := string(f.buf[:i])
		f.buf = f.buf[i+1:]
		if strings.HasPrefix(line, "Uplink") || strings.HasPrefix(line, "Downlink") {
			fmt.Printf("%s%s%s%s\n", f.prefix, ui.OK, line, ui.Rst)
		} else if strings.Contains(line, "responsiveness") {
			fmt.Printf("%s%s%s%s\n", f.prefix, ui.Dim, line, ui.Rst)
		}
	}
	return len(p), nil
}
