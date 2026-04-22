package dish

import (
	"context"
	"encoding/json"
	"fmt"
)

// Status is a trimmed view of DishGetStatus — we only decode fields we render.
// Add fields as new subcommands need them.
type Status struct {
	DeviceInfo struct {
		HardwareVersion string `json:"hardwareVersion"`
		SoftwareVersion string `json:"softwareVersion"`
		CountryCode     string `json:"countryCode"`
		Bootcount       int64  `json:"bootcount"`
	} `json:"deviceInfo"`
	DeviceState struct {
		UptimeS int64 `json:"uptimeS,string"`
	} `json:"deviceState"`
	State                  string  `json:"state"`
	ClassOfService         string  `json:"classOfService"`
	MobilityClass          string  `json:"mobilityClass"`
	SoftwareUpdateState    string  `json:"softwareUpdateState"`
	EthSpeedMbps           int     `json:"ethSpeedMbps"`
	DownlinkThroughputBps  float64 `json:"downlinkThroughputBps"`
	UplinkThroughputBps    float64 `json:"uplinkThroughputBps"`
	PopPingLatencyMs       float64 `json:"popPingLatencyMs"`
	PopPingDropRate        float64 `json:"popPingDropRate"`
	IsSnrAboveNoiseFloor   bool    `json:"isSnrAboveNoiseFloor"`
	IsSnrPersistentlyLow   bool    `json:"isSnrPersistentlyLow"`
	BoresightAzimuthDeg    float64 `json:"boresightAzimuthDeg"`
	BoresightElevationDeg  float64 `json:"boresightElevationDeg"`
	DlBandwidthRestricted  string  `json:"dlBandwidthRestrictedReason"`
	UlBandwidthRestricted  string  `json:"ulBandwidthRestrictedReason"`
	DisablementCode        string  `json:"disablementCode"`

	ObstructionStats struct {
		FractionObstructed float64 `json:"fractionObstructed"`
		ValidS             float64 `json:"validS"`
		TimeObstructed     float64 `json:"timeObstructed"`
		PatchesValid       int     `json:"patchesValid"`
	} `json:"obstructionStats"`

	AlignmentStats struct {
		DesiredBoresightAzimuthDeg   float64 `json:"desiredBoresightAzimuthDeg"`
		DesiredBoresightElevationDeg float64 `json:"desiredBoresightElevationDeg"`
		TiltAngleDeg                 float64 `json:"tiltAngleDeg"`
		AttitudeEstimationState      string  `json:"attitudeEstimationState"`
	} `json:"alignmentStats"`

	GpsStats struct {
		GpsValid bool `json:"gpsValid"`
		GpsSats  int  `json:"gpsSats"`
	} `json:"gpsStats"`

	Alerts      map[string]bool `json:"alerts"`
	ReadyStates map[string]bool `json:"readyStates"`
}

// GetStatus fetches and decodes DishGetStatus.
func (c *Client) GetStatus(ctx context.Context) (*Status, error) {
	raw, err := c.Call(ctx, []byte(`{"get_status":{}}`))
	if err != nil {
		return nil, err
	}
	// Response shape: { "dishGetStatus": { ... } }
	var wrap struct {
		DishGetStatus json.RawMessage `json:"dishGetStatus"`
	}
	if err := json.Unmarshal(raw, &wrap); err != nil {
		return nil, fmt.Errorf("decode envelope: %w", err)
	}
	var s Status
	if err := json.Unmarshal(wrap.DishGetStatus, &s); err != nil {
		return nil, fmt.Errorf("decode status: %w", err)
	}
	return &s, nil
}
