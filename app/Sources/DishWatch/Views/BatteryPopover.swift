import SwiftUI

/// Screen B — on battery. The power bank is the hero: big %, time-to-empty,
/// power facts, draw sparkline, condensed link state.
struct BatteryPopover: View {
    var d: DishData
    @Binding var showSettings: Bool
    /// Routed through PopoverView so the setup screen replaces the panel's
    /// content instead of being presented as an unclickable sheet.
    @Binding var showBankSetup: Bool
    @EnvironmentObject var store: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                hero
                facts.padding(.horizontal, 16)
                drawRow
                linkState.padding(.horizontal, 16).padding(.top, 8)
            }
            // Same treatment as the mains popover. Without it the battery
            // layout kept counting "dies in 2h 18m" off a frozen wattage while
            // the helper was dead, with no signal anywhere in the panel.
            .opacity(store.quality.isTrustworthy ? 1 : 0.5)
            .saturation(store.quality.isTrustworthy ? 1 : 0)
            footer
        }
        .foregroundStyle(DW.text)
        .overlay(TopGlow(color: DW.amber, height: 120), alignment: .top)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                BatteryGlyph(fraction: d.bankPct / 100, color: DW.amber, width: 24, height: 12)
                Text("On battery").font(.system(size: 14, weight: .bold))
            }
            Spacer()
            Text(Date.now, format: .dateTime.hour().minute().second())
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(DW.textA(0.5))
            AppMenuButton(showSettings: $showSettings, refresh: { Task { await store.refresh() } })
        }
        .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 8)
    }

    private var hero: some View {
        VStack(spacing: 0) {
            Text("POWER BANK").font(.system(size: 13, weight: .semibold)).tracking(0.5)
                .foregroundStyle(DW.amber.opacity(0.9))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(d.bankPct))").font(.system(size: 58, weight: .heavy)).monospacedDigit()
                Text("%").font(.system(size: 26, weight: .semibold)).foregroundStyle(DW.textA(0.6))
            }
            .padding(.top, 6)
            // big bar
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
                .frame(maxWidth: 300).frame(height: 16)
                .overlay(
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 6).fill(DW.amberFill)
                            .padding(2.5)
                            .frame(width: (g.size.width) * d.bankPct / 100)
                    }, alignment: .leading)
                .padding(.top, 16)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("dies in").font(.system(size: 12)).foregroundStyle(DW.textA(0.5))
                timeToEmpty
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 18)
    }

    private var timeToEmpty: some View {
        let h = d.bankSecondsLeft / 3600
        let m = (d.bankSecondsLeft % 3600) / 60
        return (
            Text("\(h)").font(.system(size: 30, weight: .bold)).monospacedDigit()
            + Text("h ").font(.system(size: 17, weight: .semibold)).foregroundColor(DW.textA(0.6))
            + Text("\(m)").font(.system(size: 30, weight: .bold)).monospacedDigit()
            + Text("m").font(.system(size: 17, weight: .semibold)).foregroundColor(DW.textA(0.6))
        )
    }

    private var facts: some View {
        HStack(spacing: 1) {
            fact(String(format: "%.1f", d.powerW), "watts now")
            fact(String(format: "%.1f", d.bankWhLeft), "Wh left")
            fact("\(Int(d.bankWh))", "bank Wh")
        }
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func fact(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 17, weight: .bold)).monospacedDigit()
            Text(label).font(.system(size: 10)).foregroundStyle(DW.textA(0.45))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 11)
        .background(DW.cellBG.opacity(0.8))
    }

    /// The power trace, captioned and windowed like the mains popover's.
    ///
    /// It had neither. The window is one setting shared by both surfaces — a
    /// bank user's `powerSeries` is already however wide the last poll asked for
    /// — so without a caption this row silently changed length, and without a
    /// control the only way to widen it was to unplug the bank. Both surfaces
    /// draw from the same series; they should say the same thing about it.
    @ViewBuilder private var drawRow: some View {
        if d.powerSeries.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(text: "Draw · last \(ConnectedPopover.span(d.seriesSeconds))").tracking(0.8)
                    Spacer()
                    HStack(spacing: 3) {
                        ForEach(AppState.historyWindows, id: \.self) { secs in
                            let on = store.historyWindow == secs
                            Button { store.historyWindow = secs } label: {
                                Text(ConnectedPopover.span(secs))
                                    .font(.system(size: 10.5, weight: on ? .semibold : .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(on ? Color(hex: 0x04121B) : DW.textA(0.55))
                                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                                    .background(on ? DW.amber : Color.white.opacity(0.06),
                                                in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show the last \(ConnectedPopover.span(secs))")
                        }
                    }
                }
                HStack(spacing: 11) {
                    Spark(values: d.powerSeries, color: DW.amber).frame(height: 22)
                    Text("avg \(d.powerAvg, specifier: "%.1f")").font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(DW.textA(0.45)).frame(width: 52, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
        }
    }

    private var linkState: some View {
        let stats = ["\(Int(d.downMbps)) Mbps", "\(Int(d.pingMs)) ms", "sig \(d.signalScore)"]
        return HStack(spacing: 9) {
            StatusDot(color: {
            switch d.state {
            case .connected: return DW.green
            case .weak:      return DW.amber
            case .disabled, .offline: return DW.red
            }
        }(), size: 8, pulse: false)
            Text(d.stateLabel).font(.system(size: 12, weight: .semibold))
            ForEach(stats, id: \.self) { s in
                Text("·").foregroundStyle(DW.textA(0.4))
                Text(s).font(.system(size: 12)).foregroundStyle(DW.textA(0.62))
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var footer: some View {
        HStack {
            Text("anchored \(d.anchoredAgoText)").font(.system(size: 11)).foregroundStyle(DW.textA(0.4))
            Spacer()
            DWButton(title: "Adjust bank…") { showBankSetup = true }
        }
        .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 15)
    }
}
