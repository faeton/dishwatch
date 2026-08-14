//go:build !apphelper

package main

// Capabilities present in the standalone CLI but deliberately absent from the
// helper the macOS app embeds. See features_apphelper.go for the other half and
// for why the split exists.

import (
	"context"

	"github.com/faeton/dishwatch/internal/geo"
)

const helperOnlyBuild = false

// reverseGeocode resolves coordinates to a place name via OpenStreetMap
// Nominatim, cached on disk per ~1 km cell.
func reverseGeocode(ctx context.Context, lat, lon float64) (string, error) {
	return geo.Reverse(ctx, lat, lon)
}
