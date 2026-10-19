import SwiftUI

/// The power bank, as a card inside the status panel.
///
/// This used to be a whole screen of its own ("Screen B"): anchoring a bank
/// swapped the status panel out for a battery layout, with no way back to the
/// link while the anchor stood. It took the metric grid, the ping and
/// throughput traces, the observed stats, the detail row, Reboot and Pin with
/// it — on a power bank, which is exactly when you are somewhere the link is
/// worth watching. A bank is one more thing the dish is doing, not a mode, so
/// it is a card on the one panel.
///
/// The draw trace that screen carried is not repeated here: the status panel's
/// own Power trace is the same series under the same window control.
struct BankCard: View {
    var d: DishData
    var onAdjust: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                BatteryGlyph(fraction: d.bankPct / 100, color: DW.amber, width: 22, height: 11)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                SectionLabel(text: "Power bank")
                Text("\(Int(d.bankPct))%").font(.system(size: 20, weight: .bold)).monospacedDigit()
                Spacer(minLength: 6)
                runtime
            }
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.white.opacity(0.08))
                .frame(height: 8)
                .overlay(
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 4).fill(DW.amberFill)
                            .padding(1.5)
                            .frame(width: g.size.width * min(max(d.bankPct, 0), 100) / 100)
                    }, alignment: .leading)
            HStack(spacing: 8) {
                Text(facts).font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(DW.textA(0.55))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                DWButton(title: "Adjust…", action: onAdjust)
            }
        }
        .padding(13)
        .background(DW.amber.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(DW.amber.opacity(0.22), lineWidth: 0.5))
    }

    private var facts: String {
        String(format: "%.1f of %.0f Wh left · anchored %@", d.bankWhLeft, d.bankWh, d.anchoredAgoText)
    }

    /// Three answers, not two. Zero seconds is the "no honest average"
    /// sentinel from `dashboard.go` — unless the bank itself is at zero, in
    /// which case it is the answer and "no measured draw" would blame the
    /// wrong thing. Rendering the sentinel as a duration read "0h 0m", a
    /// confident wrong number on the one readout this feature exists for.
    @ViewBuilder private var runtime: some View {
        if d.bankSecondsLeft > 0 {
            (Text("dies in ").font(.system(size: 11.5)).foregroundColor(DW.textA(0.5))
             + Text(Self.duration(d.bankSecondsLeft)).font(.system(size: 14, weight: .semibold)))
                .monospacedDigit()
        } else if d.bankWhLeft <= 0 {
            Text("empty by estimate").font(.system(size: 12, weight: .semibold)).foregroundStyle(DW.amber)
        } else {
            Text("runtime unknown").font(.system(size: 12)).foregroundStyle(DW.textA(0.5))
        }
    }

    static func duration(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
