import SwiftUI

/// Screen C — the always-on-top pinned widget. A condensed glanceable card.
struct CompactWidget: View {
    var d: DishData
    /// When set (pinned-panel context), shows an × that unpins the widget.
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            pinHeader
            statusRow.padding(.horizontal, 13).padding(.top, 6)
            throughput.padding(.horizontal, 13).padding(.top, 11)
            tripleStat.padding(.horizontal, 14).padding(.top, 10)
            if d.bankAnchored { batteryCard.padding(11) }
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

    private var statusRow: some View {
        HStack(spacing: 9) {
            StatusDot(color: d.state == .connected ? DW.green : DW.amber, pulse: false)
            Text(d.stateLabel).font(.system(size: 15, weight: .bold))
            Spacer()
            Text("\(d.signalScore)").font(.system(size: 11)).monospacedDigit().foregroundStyle(DW.textA(0.5))
            SignalBars(color: DW.cyan, height: 14, barWidth: 3, fraction: Double(d.signalScore) / 100)
        }
    }

    private var throughput: some View {
        HStack(spacing: 1) {
            tputCell("↓ DOWN", "avg \(Int(d.downAvg))", "\(Int(d.downMbps))", d.downSeries, DW.down)
            tputCell("↑ UP", "avg \(Int(d.upAvg))", String(format: "%.1f", d.upMbps), d.upSeries, DW.up)
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

    private var tripleStat: some View {
        HStack {
            stat("\(Int(d.pingMs))", "ms", "ping", DW.text)
            Spacer()
            stat(String(format: "%.1f", d.dropPct), "%", "drop", DW.green)
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
