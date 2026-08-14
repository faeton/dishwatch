import SwiftUI

/// Screen C — the always-on-top pinned widget. A condensed glanceable card.
struct CompactWidget: View {
    var d: DishData
    /// When set (pinned-panel context), shows an × that unpins the widget.
    var onClose: (() -> Void)? = nil
    /// Provenance of the numbers below. Defaults to `.live` only so the render
    /// harness and previews stay simple; the real panel always passes the
    /// store's value.
    ///
    /// This widget had no provenance signal of any kind, which mattered more
    /// here than anywhere else in the app: it is always on top, and with no
    /// helper the sample provider animates 142.5 Mbps with a moving sparkline.
    /// The popover has said "sample data" for a while; this never did.
    var quality: AppState.Quality = .live

    private var trustworthy: Bool { quality.isTrustworthy }

    var body: some View {
        VStack(spacing: 0) {
            pinHeader
            provenanceBar
            Group {
                statusRow.padding(.horizontal, 13).padding(.top, 6)
                throughput.padding(.horizontal, 13).padding(.top, 11)
                tripleStat.padding(.horizontal, 14).padding(.top, 10)
                if d.bankAnchored { batteryCard.padding(11) }
            }
            .opacity(trustworthy ? 1 : 0.5)
            .saturation(trustworthy ? 1 : 0)
        }
        .foregroundStyle(DW.text)
        .frame(width: 316)
        .background(DW.panel(0.97, 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }

    private var pinHeader: some View {
        HStack {
            HStack(spacing: 4) {
                Circle().fill(Color.white.opacity(0.18)).frame(width: 6, height: 6)
                Circle().fill(Color.white.opacity(0.18)).frame(width: 6, height: 6)
            }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "pin.fill").font(.system(size: 9))
                Text("PINNED").font(.system(size: 10, weight: .semibold)).tracking(0.3)
            }.foregroundStyle(DW.cyan)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DW.textA(0.5)).padding(4)
                }.buttonStyle(.plain).help("Unpin")
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
    }

    /// One line, only when the numbers are not current. Silent in the normal
    /// case so the widget stays as small as it was.
    @ViewBuilder private var provenanceBar: some View {
        if !trustworthy {
            let (text, tint): (String, Color) = {
                switch quality {
                case .sample:        return ("SAMPLE DATA — NOT A REAL DISH", DW.amber)
                case .brokenInstall: return ("HELPER MISSING", DW.red)
                case .loading:       return ("CONNECTING…", DW.textA(0.6))
                case .offline:       return ("NO DISH FOUND", DW.red)
                case .stale:         return ("STALE — LAST KNOWN READING", DW.amber)
                case .live, .disabled: return ("", DW.green)
                }
            }()
            Text(text)
                .font(.system(size: 9, weight: .bold)).tracking(0.4)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(tint.opacity(0.14))
        }
    }

    private var statusRow: some View {
        HStack(spacing: 9) {
            StatusDot(color: dotColor, pulse: false)
            Text(d.stateLabel).font(.system(size: 15, weight: .bold))
            Spacer()
            Text("\(d.signalScore)").font(.system(size: 11)).monospacedDigit().foregroundStyle(DW.textA(0.5))
            SignalBars(color: DW.cyan, height: 14, barWidth: 3, fraction: Double(d.signalScore) / 100)
        }
    }

    /// Peak over the observed session, or an em-dash before there is one.
    ///
    /// These cells read `avg <n>` — a 60-second *mean* throughput presented as
    /// what the link can do. docs/macos-ui.md calls that the dangerous defect
    /// and it is: mean throughput measures utilization, so an idle dish on a
    /// flawless link renders `avg 3`, which a user reads as broken. The number
    /// was correct and the impression it created was false.
    ///
    /// The em-dash is the specified cold-start string. Explicitly *not* a
    /// silent fall back to the 60-second mean, which is the failure this
    /// replaces, and not `peak 0`, which states a measurement nobody took.
    private func peakLabel(_ value: Double?) -> String {
        guard let v = value else { return "peak —" }
        return "peak \(Int(v))"
    }

    private var throughput: some View {
        HStack(spacing: 1) {
            tputCell("↓ DOWN", peakLabel(d.observed?.downPeak), "\(Int(d.downMbps))", d.downSeries, DW.down)
            tputCell("↑ UP", peakLabel(d.observed?.upPeak), String(format: "%.1f", d.upMbps), d.upSeries, DW.up)
        }
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func tputCell(_ label: String, _ avg: String, _ value: String, _ series: [Double], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(DW.textA(0.45))
                Spacer()
                Text(avg).font(.system(size: 9.5)).monospacedDigit().foregroundStyle(DW.textA(0.4))
            }
            (Text(value).font(.system(size: 18, weight: .bold)).monospacedDigit()
             + Text(" Mbps").font(.system(size: 9.5)).foregroundColor(DW.textA(0.5)))
            Spark(values: series, color: color, fill: false, lineWidth: 1.3).frame(height: 15).padding(.top, 4)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DW.cellBG.opacity(0.85))
    }

    /// Matches ConnectedPopover.dotColor. The two surfaces disagreed: this one
    /// mapped everything non-connected to amber, so a dead dish read as a
    /// warning here and as an error there — and the always-visible surface was
    /// the one being gentler about it.
    private var dotColor: Color {
        switch d.state {
        case .connected: return DW.green
        case .weak:      return DW.amber
        case .disabled, .offline: return DW.red
        }
    }

    /// Drop was hardcoded green, so 100% packet loss rendered in the colour that
    /// means healthy. Colour is doing real work in a glanceable widget.
    private var dropColor: Color {
        if d.dropPct >= 5 { return DW.red }
        if d.dropPct >= 0.5 { return DW.amber }
        return DW.green
    }

    private var tripleStat: some View {
        HStack {
            stat("\(Int(d.pingMs))", "ms", "ping", DW.text)
            Spacer()
            stat(String(format: "%.1f", d.dropPct), "%", "drop", dropColor)
            Spacer()
            stat(String(format: "%.1f", d.powerW), "W", "draw", DW.amber)
        }
    }

    private func stat(_ value: String, _ unit: String, _ label: String, _ color: Color) -> some View {
        (Text(value).font(.system(size: 15, weight: .bold)).foregroundColor(color)
         + Text(" \(unit)").font(.system(size: 9.5)).foregroundColor(DW.textA(0.5))
         + Text(" \(label)").font(.system(size: 9.5)).foregroundColor(DW.textA(0.35)))
            .monospacedDigit()
    }

    private var batteryCard: some View {
        VStack(spacing: 8) {
            HStack {
                Text("BATTERY · \(Int(d.bankWh)) Wh").font(.system(size: 10.5, weight: .bold)).tracking(0.3)
                    .foregroundStyle(DW.amber.opacity(0.95))
                Spacer()
                Text("Set %…").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(hex: 0xFFC766))
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(DW.amber.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
            }
            HStack(spacing: 10) {
                (Text("\(Int(d.bankPct))").font(.system(size: 24, weight: .heavy))
                 + Text("%").font(.system(size: 13, weight: .semibold)).foregroundColor(DW.textA(0.55)))
                    .monospacedDigit()
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.1)).frame(height: 8)
                        .overlay(GeometryReader { g in
                            RoundedRectangle(cornerRadius: 4).fill(DW.amberFill)
                                .padding(1.5).frame(width: g.size.width * d.bankPct / 100)
                        }, alignment: .leading)
                    HStack {
                        (Text(d.bankTimeLeftText).font(.system(size: 10.5, weight: .semibold))
                         + Text(" left").font(.system(size: 10.5)).foregroundColor(DW.textA(0.6))).monospacedDigit()
                        Spacer()
                        Text("\(d.bankWhLeft, specifier: "%.1f") Wh · \(d.powerW, specifier: "%.1f") W")
                            .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(DW.textA(0.6))
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(DW.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(DW.amber.opacity(0.22), lineWidth: 0.5))
    }
}
