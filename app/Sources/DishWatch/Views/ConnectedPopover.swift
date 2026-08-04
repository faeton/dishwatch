import SwiftUI

/// Screen A — connected, on mains. Gauge + metric grid + sparklines + detail.
struct ConnectedPopover: View {
    var d: DishData
    @Binding var showSettings: Bool
    @EnvironmentObject var store: AppState
    @State private var detailExpanded = false
    @State private var confirmReboot = false

    var body: some View {
        VStack(spacing: 0) {
            header
            hero
            Divider().background(DW.hairline).padding(.horizontal, 16)
            metricGrid.padding(.top, 14).padding(.horizontal, 16)
            sparklines.padding(.top, 4)
            detailRow.padding(.horizontal, 16).padding(.top, 6)
            footer
        }
        .foregroundStyle(DW.text)
        .overlay(TopGlow(color: DW.cyan), alignment: .top)
        .confirmationDialog("Reboot the dish?", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("Reboot", role: .destructive) { Task { await store.reboot() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The dish will drop the connection for ~1–2 minutes.")
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                SignalBars(color: DW.cyan, height: 13, barWidth: 3, fraction: Double(d.signalScore) / 100)
                Text("DishWatch").font(.system(size: 14, weight: .bold))
            }
            Spacer()
            HStack(spacing: 10) {
                Text(Date.now, format: .dateTime.hour().minute().second())
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(DW.textA(0.5))
                AppMenuButton(showSettings: $showSettings, refresh: { Task { await store.refresh() } })
            }
        }
        .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 10)
    }

    private var hero: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    StatusDot(color: dotColor, pulse: store.hasLoaded && d.state == .connected)
                    Text(heroLabel).font(.system(size: 22, weight: .bold))
                }
                Text("up \(d.uptimeHours, specifier: "%.1f") h · boots \(d.boots) · \(d.hardwareShort)")
                    .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(DW.textA(0.55))
                    .padding(.top, 7)
                Text("\(d.deviceId) · fw \(d.firmware)")
                    .font(.system(size: 11.5)).foregroundStyle(DW.textA(0.38))
                    .padding(.top, 2)
            }
            Spacer()
            SignalGauge(score: d.signalScore, size: 78)
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 16)
    }

    private var metricGrid: some View {
        Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            GridRow {
                MetricCell(label: "Download", value: String(format: "%.1f", d.downMbps), unit: "Mbps",
                           barFrac: d.downBarFrac, barColor: DW.down)
                MetricCell(label: "Upload", value: String(format: "%.1f", d.upMbps), unit: "Mbps",
                           barFrac: d.upBarFrac, barColor: DW.down)
            }
            GridRow {
                MetricCell(label: "Ping", value: "\(Int(d.pingMs))", unit: "ms",
                           sub: "drop \(String(format: "%.1f", d.dropPct))% · \(d.noiseOK ? "noise ✓" : "noise ✗")")
                MetricCell(label: "Power", value: String(format: "%.1f", d.powerW), unit: "W",
                           sub: "\(String(format: "%.1f", d.energyWhSinceBoot)) Wh since boot")
            }
        }
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var sparklines: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionLabel(text: "Last 60 s").tracking(0.8)
            sparkRow("Ping", d.pingSeries, DW.cyan, "avg \(Int(d.pingAvg)) ms")
            sparkRow("Down", d.downSeries, DW.down, "max \(Int(d.downMax))")
            sparkRow("Power", d.powerSeries, DW.amber, "avg \(String(format: "%.1f", d.powerAvg)) W")
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
    }

    private func sparkRow(_ name: String, _ series: [Double], _ color: Color, _ trailing: String) -> some View {
        HStack(spacing: 12) {
            Text(name).font(.system(size: 11)).foregroundStyle(DW.textA(0.55)).frame(width: 42, alignment: .leading)
            Spark(values: series, color: color).frame(height: 24)
            Text(trailing).font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(DW.textA(0.45)).frame(width: 60, alignment: .trailing)
        }
    }

    private var detailRow: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { detailExpanded.toggle() }
            } label: {
                HStack {
                    HStack(spacing: 16) {
                        Text("◎ Aim \(Int(d.azimuthDeg))° / \(Int(d.elevationDeg))°")
                        Text("⌖ GPS \(d.gpsValid ? "✓" : "✗") \(d.gpsSats)")
                        Text("⎈ \(d.ethMbps) Mbps")
                    }
                    .font(.system(size: 11.5)).foregroundStyle(DW.textA(0.6))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(DW.textA(0.35))
                        .rotationEffect(.degrees(detailExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if detailExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    detailLine("Azimuth", "\(Int(d.azimuthDeg))°")
                    detailLine("Elevation", "\(Int(d.elevationDeg))°")
                    detailLine("GPS", "\(d.gpsValid ? "lock" : "no fix") · \(d.gpsSats) sats")
                    detailLine("Ethernet", "\(d.ethMbps) Mbps")
                }
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var heroLabel: String {
        store.hasLoaded ? d.stateLabel : "Connecting…"
    }

    private var dotColor: Color {
        guard store.hasLoaded else { return DW.textA(0.4) }
        switch d.state {
        case .connected: return DW.green
        case .offline, .disabled: return DW.red
        case .weak: return DW.amber
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11.5)).foregroundStyle(DW.textA(0.45))
            Spacer()
            Text(value).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(DW.textA(0.75))
        }
    }

    private var footer: some View {
        // Sample mode has to say so here, not only in Settings. Without the CLI
        // the app still renders a complete, plausible dashboard, and a footer
        // reading "live" over mockup numbers is the same class of lie as a
        // missing field decoding to a design constant.
        let status: String
        if !store.isLive {
            status = "sample data — no dishwatch CLI found"
        } else if !store.hasLoaded {
            status = "connecting…"
        } else {
            status = store.lastError == nil ? "live" : "stale"
        }
        let live = store.isLive && store.lastError == nil && store.hasLoaded
        return HStack {
            Text("\(d.dishAddr) · \(status)")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(live ? DW.textA(0.38) : DW.amber.opacity(0.8))
            Spacer()
            HStack(spacing: 7) {
                DWButton(title: "Reboot") { confirmReboot = true }
                // The only window we own to "open" is the always-on-top compact
                // widget — the dish has no real web app to launch.
                DWButton(title: store.pinnedWidget ? "Unpin" : "Pin", prominent: true) {
                    store.pinnedWidget.toggle()
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 15)
    }
}

/// One cell of the 2×2 metric grid.
struct MetricCell: View {
    var label: String
    var value: String
    var unit: String
    var sub: String? = nil
    var barFrac: Double? = nil
    var barColor: Color = DW.down

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: label)
            (Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit()
             + Text(" \(unit)").font(.system(size: 11, weight: .regular)).foregroundColor(DW.textA(0.5)))
                .padding(.top, 4)
            if let barFrac {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(barColor).frame(width: max(2, g.size.width * barFrac))
                    }
                }
                .frame(height: 3).padding(.top, 7)
            } else if let sub {
                Text(sub).font(.system(size: 11)).foregroundStyle(DW.textA(0.45)).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(DW.cellBG.opacity(0.7))
    }
}
