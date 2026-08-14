//go:build apphelper

package main

// The `apphelper` build is what ships inside DishWatch.app as
// Contents/MacOS/dishwatch-helper. It is the same engine, minus everything the
// app never asks for.
//
// This exists because the bundle used to embed a straight copy of the full CLI.
// The app uses four operations — poll, reboot, setAnchor, ping — but the binary
// it shipped also carried:
//
//   - `speed`, which exec's ping(8) and networkQuality(1). Neither can run
//     under the sandbox, and shipping a nested tool that shells out is a poor
//     thing to hand App Review. Its banner also read "Starlink speed test",
//     putting the wordmark in the submitted binary for a feature the app
//     cannot invoke.
//   - `raw`, which sends caller-supplied gRPC to an arbitrary address.
//   - the Nominatim reverse geocoder, which talks to a third-party HTTP service.
//     Nothing in the app's data path geocodes, so its presence in the bundle
//     contradicted Info.plist's claim that nothing is sent anywhere else — a
//     claim a reviewer can check with strings(1).
//
// Excluding them at compile time is the only version of that claim that stays
// true as the code changes.

import (
	"context"
	"errors"
)

const helperOnlyBuild = true

var errNotInHelper = errors.New("not available in the bundled helper build")

func reverseGeocode(_ context.Context, _, _ float64) (string, error) {
	return "", nil // no third-party geocoding in the shipped helper
}
