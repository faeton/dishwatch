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
	// Nominatim's usage policy requires a User-Agent that identifies the
	// application *and* carries contact information; a bare tool name is the
	// documented reason clients get blocked. This was "sl-cli/1.0".
	userAgent = "dishwatch/1.0 (+https://github.com/faeton/dishwatch)"
	timeout   = 3 * time.Second
	// unknownLabel is cached like any other result, but only for negativeTTL —
	// see Reverse.
	unknownLabel = "unknown"
	negativeTTL  = 6 * time.Hour
	endpoint     = "https://nominatim.openstreetmap.org/reverse"
)

// Reverse returns a "Town, Region, Country" label for (lat, lon). On miss it
// queries Nominatim; on success it writes the result to the cache. Failures
// return "unknown" (also cached, to avoid retry storms).
func Reverse(ctx context.Context, lat, lon float64) (string, error) {
	cache, err := cachePath(lat, lon)
	if err != nil {
		return "", err
	}
	// A cached failure expires; a cached place name does not. Coordinates do
	// not move, so a real label is good forever — but "unknown" used to be
	// written with the same permanence, so one transient DNS failure, one 429,
	// or one captive portal poisoned that cell for good and the Place line
	// silently fell back to a country code with no retry, ever.
	if b, err := os.ReadFile(cache); err == nil && len(b) > 0 {
		label := string(b)
		if label != unknownLabel {
			return label, nil
		}
		if fi, err := os.Stat(cache); err == nil && time.Since(fi.ModTime()) < negativeTTL {
			return label, nil
		}
		// Stale negative entry — fall through and try again.
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
		_ = os.WriteFile(cache, []byte(unknownLabel), 0o644)
		return unknownLabel, nil
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return unknownLabel, nil
	}

	label := parseNominatim(body)
	if label == "" {
		label = unknownLabel
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
