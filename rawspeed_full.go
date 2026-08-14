//go:build !apphelper

package main

// `raw` and `speed` live here because they are excluded from the helper build
// that ships inside the app bundle: `raw` sends caller-supplied gRPC to an
// arbitrary address, and `speed` exec's ping(8) and networkQuality(1), neither
// of which can run sandboxed. See features_apphelper.go.

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
