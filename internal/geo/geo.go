// Package geo does reverse-geocoding via OpenStreetMap's Nominatim. Results
// are cached on disk (~/.cache/sl/geo_<lat>_<lon>.txt) per ~1 km cell so
// repeated calls from a stationary dish don't hammer the service.
package geo

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/faeton/dishwatch/internal/state"
)

const (
	userAgent = "sl-cli/1.0"
	timeout   = 3 * time.Second
	endpoint  = "https://nominatim.openstreetmap.org/reverse"
)

// Reverse returns a "Town, Region, Country" label for (lat, lon). On miss it
// queries Nominatim; on success it writes the result to the cache. Failures
// return "unknown" (also cached, to avoid retry storms).
func Reverse(ctx context.Context, lat, lon float64) (string, error) {
	cache, err := cachePath(lat, lon)
	if err != nil {
		return "", err
	}
	if b, err := os.ReadFile(cache); err == nil && len(b) > 0 {
		return string(b), nil
	}

	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	url := fmt.Sprintf("%s?lat=%f&lon=%f&zoom=12&format=json&accept-language=en", endpoint, lat, lon)
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", userAgent)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		_ = os.WriteFile(cache, []byte("unknown"), 0o644)
		return "unknown", nil
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return "unknown", nil
	}

	label := parseNominatim(body)
	if label == "" {
		label = "unknown"
	}
	_ = os.WriteFile(cache, []byte(label), 0o644)
	return label, nil
}

func cachePath(lat, lon float64) (string, error) {
	d, err := state.CacheDir()
	if err != nil {
		return "", err
	}
	// 2 decimals ≈ 1.1 km grid at the equator — same granularity as bash.
	return filepath.Join(d, fmt.Sprintf("geo_%.2f_%.2f.txt", lat, lon)), nil
}

// parseNominatim picks city/town/village/suburb/county, then state, then
// country — first non-empty in each tier — and joins them with ", ".
func parseNominatim(body []byte) string {
	var r struct {
		Address map[string]string `json:"address"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		return ""
	}
	pick := func(keys ...string) string {
		for _, k := range keys {
			if v := r.Address[k]; v != "" {
				return v
			}
		}
		return ""
	}
	var parts []string
	if v := pick("city", "town", "village", "suburb", "county"); v != "" {
		parts = append(parts, v)
	}
	if v := r.Address["state"]; v != "" {
		parts = append(parts, v)
	}
	if v := r.Address["country"]; v != "" {
		parts = append(parts, v)
	}
	out := ""
	for i, p := range parts {
		if i > 0 {
			out += ", "
		}
		out += p
	}
	return out
}
