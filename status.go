package main

import (
	"context"
	"fmt"
	"sort"
	"strings"
)

func runStatus(ctx context.Context) error {
	c, err := dialDish(ctx)
	if err != nil {
		return err
	}
	defer c.Close()

	s, err := c.GetStatus(ctx)
	if err != nil {
		return err
	}

	state := s.State
	if state == "" {
		if allTrue(s.ReadyStates) {
			state = "CONNECTED"
		} else {
			state = "NOT READY"
		}
	}

	uptime := s.DeviceState.UptimeS
	downMbps := s.DownlinkThroughputBps / 1e6
	upMbps := s.UplinkThroughputBps / 1e6
	dropPct := s.PopPingDropRate * 100
	obsPct := s.ObstructionStats.FractionObstructed * 100
	timeObsPct := s.ObstructionStats.TimeObstructed * 100

	fmt.Printf("State:        %s\n", state)
	fmt.Printf("Uptime:       %.1f h  (%ds, boots=%d)\n", float64(uptime)/3600, uptime, s.DeviceInfo.Bootcount)
	fmt.Printf("Hardware:     %s   class=%s   mobility=%s   country=%s\n",
		s.DeviceInfo.HardwareVersion, dashIf(s.ClassOfService),
		dashIf(s.MobilityClass), dashIf(s.DeviceInfo.CountryCode))
	fmt.Printf("Software:     %s   swupdate=%s\n",
		s.DeviceInfo.SoftwareVersion, dashIf(s.SoftwareUpdateState))
	fmt.Printf("Throughput:   down %.2f Mbps   up %.2f Mbps\n", downMbps, upMbps)
	fmt.Printf("Ping (pop):   %.1f ms   drop=%.1f%%\n", s.PopPingLatencyMs, dropPct)
	fmt.Printf("SNR:          aboveNoise=%t   persistentlyLow=%t\n",
		s.IsSnrAboveNoiseFloor, s.IsSnrPersistentlyLow)
	fmt.Printf("Obstruction:  %.2f%%   validS=%.0f   timeObstructed=%.2f%%   patches=%d\n",
		obsPct, s.ObstructionStats.ValidS, timeObsPct, s.ObstructionStats.PatchesValid)
	fmt.Printf("Aim:          az=%.1f deg   el=%.1f deg   tilt=%.1f deg   attitude=%s\n",
		s.BoresightAzimuthDeg, s.BoresightElevationDeg,
		s.AlignmentStats.TiltAngleDeg, dashIf(s.AlignmentStats.AttitudeEstimationState))
	fmt.Printf("GPS:          valid=%t   sats=%d\n", s.GpsStats.GpsValid, s.GpsStats.GpsSats)
	fmt.Printf("Ethernet:     %d Mbps\n", s.EthSpeedMbps)
	fmt.Printf("Ready:        %s\n", joinMap(s.ReadyStates))
	fmt.Printf("Bandwidth:    dl=%s   ul=%s   disablement=%s\n",
		dashIf(s.DlBandwidthRestricted), dashIf(s.UlBandwidthRestricted),
		dashIf(s.DisablementCode))
	fmt.Printf("Alerts:       %s\n", joinActiveAlerts(s.Alerts))
	return nil
}

func allTrue(m map[string]bool) bool {
	if len(m) == 0 {
		return false
	}
	for _, v := range m {
		if !v {
			return false
		}
	}
	return true
}

func joinMap(m map[string]bool) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%t", k, m[k]))
	}
	return strings.Join(parts, " ")
}

func joinActiveAlerts(m map[string]bool) string {
	var active []string
	for k, v := range m {
		if v {
			active = append(active, k)
		}
	}
	if len(active) == 0 {
		return "none"
	}
	sort.Strings(active)
	return strings.Join(active, ", ")
}

