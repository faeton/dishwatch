package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
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

// ---- helpers ----

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
