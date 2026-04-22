package dish

import (
	"context"
	"encoding/json"
	"fmt"
)

// History is a trimmed view of DishGetHistory. `Current` is a monotonic write
// cursor into the ring buffers below; (Current-1) % len is the newest sample.
type History struct {
	Current               int64     `json:"current,string"`
	PopPingLatencyMs      []float64 `json:"popPingLatencyMs"`
	PopPingDropRate       []float64 `json:"popPingDropRate"`
	DownlinkThroughputBps []float64 `json:"downlinkThroughputBps"`
	UplinkThroughputBps   []float64 `json:"uplinkThroughputBps"`
	PowerIn               []float64 `json:"powerIn"`
}

// GetHistory fetches and decodes DishGetHistory.
func (c *Client) GetHistory(ctx context.Context) (*History, error) {
	raw, err := c.Call(ctx, []byte(`{"get_history":{}}`))
	if err != nil {
		return nil, err
	}
	var wrap struct {
		DishGetHistory json.RawMessage `json:"dishGetHistory"`
	}
	if err := json.Unmarshal(raw, &wrap); err != nil {
		return nil, fmt.Errorf("decode envelope: %w", err)
	}
	var h History
	if err := json.Unmarshal(wrap.DishGetHistory, &h); err != nil {
		return nil, fmt.Errorf("decode history: %w", err)
	}
	return &h, nil
}

// LastN returns the last n samples from a ring buffer (oldest→newest).
// If n > len(ring), all samples are returned.
func (h *History) LastN(ring []float64, n int) []float64 {
	l := len(ring)
	if l == 0 {
		return nil
	}
	if n > l {
		n = l
	}
	cur := int(h.Current)
	if cur <= 0 {
		return nil
	}
	out := make([]float64, n)
	for i := 0; i < n; i++ {
		idx := ((cur-n+i)%l + l) % l
		out[i] = ring[idx]
	}
	return out
}

// Latest returns the single most-recent sample, or (0, false) if unavailable.
func (h *History) Latest(ring []float64) (float64, bool) {
	l := len(ring)
	if l == 0 || h.Current <= 0 {
		return 0, false
	}
	idx := ((int(h.Current)-1)%l + l) % l
	return ring[idx], true
}
