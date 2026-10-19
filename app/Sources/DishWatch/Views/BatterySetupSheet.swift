import SwiftUI

/// Battery setup sheet → maps to `sl pb <pct> <wh>`. Pick charge + capacity,
/// optionally calibrate.
struct BatterySetupSheet: View {
    var d: DishData
    /// Called with the values the user chose. Non-optional on purpose: this
    /// sheet's entire job is to produce an anchor, and the previous version
    /// took no callback at all — "Start tracking" was a comment plus
    /// `dismiss()`, and "Calibrate" had no action, so it inherited DWButton's
    /// default empty closure and compiled without a warning. Every control on
    /// the sheet moved and none of them wrote anything.
    var onAnchor: (_ pct: Double, _ wh: Double?) -> Void
    /// Maps to `sl pb off`. `nil` leaves "Stop tracking" off the sheet.
    var onClear: (() -> Void)? = nil
    var onDone: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var charge: Double
    @State private var capacity: Double
    @State private var showCustom = false
    @State private var customText = ""
    /// Banks are sold by mAh at least as often as by Wh, and the mAh figure is
    /// the one printed biggest. The engine only knows Wh, so mAh is converted
    /// here and never leaves this sheet. Wh stays the default; the choice is
    /// remembered for the next time.
    @AppStorage("bankCapacityUnit") private var unit: CapacityUnit = .wh
    @State private var voltsText = "3.7"
    private let presets: [Double] = [27, 67, 100, 230]

    enum CapacityUnit: String { case wh, mAh }

    /// Every capacity this sheet accepts or displays. The ceiling is far past
    /// any portable bank and exists so `Int(...)` on a typed `1e20` cannot trap.
    static let capacityRange: ClosedRange<Double> = 1...100_000
    /// Cell voltages, generously. Below 1 V the mAh seed divides into overflow.
    static let voltsRange: ClosedRange<Double> = 1...60

    /// Seeded from the live snapshot rather than hardcoded. Reopening "Adjust
    /// bank…" on an anchored 78% / 230 Wh bank used to show 100% / 67 Wh — it
    /// misreported the setting it existed to edit.
    init(d: DishData,
         onAnchor: @escaping (_ pct: Double, _ wh: Double?) -> Void,
         onClear: (() -> Void)? = nil,
         onDone: @escaping () -> Void = {}) {
        self.d = d
        self.onAnchor = onAnchor
        self.onClear = onClear
        self.onDone = onDone
        // `bankAnchored`, not `bankPct > 0`: an estimate run down to 0% is a
        // reading, and reopening it at 100% made Start tracking refill an empty
        // bank and Calibrate measure from the wrong end.
        _charge = State(initialValue: d.bankAnchored ? d.bankPct : 100)
        _capacity = State(initialValue: Self.capacityRange.contains(d.bankWh) ? d.bankWh : 67)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 5) {
                Text("Running on a power bank?").font(.system(size: 17, weight: .bold))
                Text("Tell DishWatch the bank's charge and capacity once — it integrates the dish's live wattage to track % and time remaining. Tracking stops if the dish restarts; set it again after.")
                    .font(.system(size: 12.5)).foregroundStyle(DW.textA(0.55)).lineSpacing(2)
            }
            .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 4)

            // current charge
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Current charge").font(.system(size: 12.5, weight: .medium)).foregroundStyle(DW.textA(0.8))
                    Spacer()
                    Text("\(Int(charge))%").font(.system(size: 15, weight: .bold)).monospacedDigit()
                }
                Slider(value: $charge, in: 0...100).tint(DW.amber)
            }
            .padding(.horizontal, 18).padding(.top, 18)

            // capacity presets
            VStack(alignment: .leading, spacing: 10) {
                Text("Bank capacity").font(.system(size: 12.5, weight: .medium)).foregroundStyle(DW.textA(0.8))
                HStack(spacing: 7) {
                    ForEach(presets, id: \.self) { wh in
                        capacityPill("\(Int(wh)) Wh", selected: capacity == wh && !showCustom) { capacity = wh; showCustom = false }
                    }
                    // Was a bare HStack styled to look exactly like the live
                    // pills beside it — a picture of a button, with no action
                    // and no custom-capacity path anywhere in the app.
                    //
                    // Labelled with the value once one is set: a capacity off the
                    // presets (74 Wh from 20 000 mAh, a calibrated 63 Wh) left no
                    // pill selected, so the sheet hid the figure it was editing.
                    let isPreset = presets.contains(capacity)
                    capacityPill(isPreset || showCustom ? "Custom" : Self.whText(capacity),
                                 selected: showCustom || !isPreset) {
                        showCustom.toggle()
                        if showCustom { seedCustom() }
                    }
                }
                if showCustom {
                    HStack(spacing: 6) {
                        capacityPill("Wh", selected: unit == .wh) { unit = .wh; seedCustom() }
                        capacityPill("mAh", selected: unit == .mAh) { unit = .mAh; seedCustom() }
                    }
                    HStack(spacing: 8) {
                        TextField(unit == .wh ? "Wh" : "mAh", text: $customText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .onSubmit(applyCustom)
                        Text(unit == .wh ? "Wh" : "mAh").font(.system(size: 12)).foregroundStyle(DW.textA(0.6))
                        if unit == .mAh {
                            Text("at").font(.system(size: 12)).foregroundStyle(DW.textA(0.6))
                            TextField("V", text: $voltsText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 48)
                                .onSubmit(applyCustom)
                            Text("V").font(.system(size: 12)).foregroundStyle(DW.textA(0.6))
                        }
                        DWButton(title: "Set", action: applyCustom)
                            .disabled(customWh == nil)
                            .opacity(customWh == nil ? 0.4 : 1)
                        Spacer()
                    }
                    if unit == .mAh {
                        Text(customWh.map { "= \(Self.whText($0)) · banks rate mAh at the cell's 3.6–3.7 V" }
                             ?? "Banks rate mAh at the cell's 3.6–3.7 V, not the 5 V USB output.")
                            .font(.system(size: 11)).foregroundStyle(DW.textA(0.5))
                    }
                }
            }
            .padding(.horizontal, 18).padding(.top, 20)

            // calibration hint
            (Text("Tip ").font(.system(size: 11.5, weight: .semibold)).foregroundColor(DW.cyan)
             + Text("Not sure of the Wh? Pick a guess, run for ~20 min, then tap Calibrate — DishWatch back-solves capacity from the % drop.")
                .font(.system(size: 11.5)).foregroundColor(DW.textA(0.55)))
                .lineSpacing(3)
                .padding(13)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
                .padding(.horizontal, 18).padding(.top, 18)

            // actions
            HStack(spacing: 8) {
                // Calibrate back-solves capacity from the drop since the last
                // anchor: Wh_consumed / (pct_drop / 100). It needs a prior
                // anchor and a measurable drop, so it is disabled until both
                // exist rather than silently doing nothing — which is what it
                // did before, since it was declared with no action at all while
                // the Tip text above told the user to tap it.
                DWButton(title: "Calibrate", action: calibrate)
                    .disabled(!canCalibrate)
                    .opacity(canCalibrate ? 1 : 0.4)
                    .help(canCalibrate
                          ? "Back-solve capacity from the charge drop since the last anchor"
                          : "Set an anchor first, then run for ~20 minutes")
                Button {
                    onAnchor(charge, capacity)
                    onDone()
                    dismiss()
                } label: {
                    Text("Start tracking").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: 0x04121B))
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(DW.cyan, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }.buttonStyle(.plain)
            }
            .padding(18)
        }
        .foregroundStyle(DW.text)
        .background(DW.panel())
        .environment(\.colorScheme, .dark)
    }

    /// Back, plus "Stop tracking" when there is an anchor to stop. The sheet
    /// had no way out but "Start tracking", so opening it to look was a
    /// commitment to re-anchor.
    private var header: some View {
        HStack {
            Button(action: { onDone(); dismiss() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Back").font(.system(size: 13))
                }
                .foregroundStyle(DW.textA(0.7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if let onClear, d.bankAnchored {
                DWButton(title: "Stop tracking", destructive: true) {
                    onClear()
                    onDone()
                    dismiss()
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 13)
    }

    /// The custom field's value in Wh, or nil if it does not parse.
    private var customWh: Double? {
        Self.wh(from: customText, unit: unit, volts: voltsText)
    }

    /// `mAh × V / 1000`. Split out so the arithmetic is testable without a view.
    static func wh(from text: String, unit: CapacityUnit, volts: String) -> Double? {
        func num(_ s: String) -> Double? {
            Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        }
        guard let v = num(text), v > 0, v.isFinite else { return nil }
        let wh: Double
        switch unit {
        case .wh:
            wh = v
        case .mAh:
            guard let volts = num(volts), voltsRange.contains(volts) else { return nil }
            wh = v * volts / 1000
        }
        return capacityRange.contains(wh) ? wh : nil
    }

    static func whText(_ wh: Double) -> String {
        // Format strings, not `Int(...)`: they cannot trap on a value out of range.
        wh >= 10 ? String(format: "%.0f Wh", wh) : String(format: "%.1f Wh", wh)
    }

    /// Fill the field with the current capacity in whichever unit is showing.
    private func seedCustom() {
        switch unit {
        case .wh:
            customText = String(format: "%.0f", capacity)
        case .mAh:
            let parsed = Double(voltsText.replacingOccurrences(of: ",", with: "."))
            let volts = parsed.map { Self.voltsRange.contains($0) ? $0 : 3.7 } ?? 3.7
            customText = String(format: "%.0f", capacity * 1000 / volts)
        }
    }

    private func applyCustom() {
        guard let wh = customWh else { return }
        capacity = (wh * 10).rounded() / 10
        showCustom = false
    }

    /// Calibration needs a prior anchor to measure from and a real drop to
    /// divide by. A 1% drop divided into a Wh figure produces a capacity with
    /// enormous quantization error, so require a few points of movement — the
    /// same reason the CLI's docs tell you to stay in the 30–80% mid-range.
    private var canCalibrate: Bool {
        d.bankAnchored && Self.calibratedCapacity(anchorPct: d.bankAnchorPct,
                                                  usedWh: d.bankUsedWh, nowPct: charge) != nil
    }

    /// `Wh_per_full_charge = Wh_consumed / (pct_drop / 100)`, the README's
    /// formula, with the drop measured from the **anchored** percentage to the
    /// one the user reads off the bank now.
    ///
    /// The previous version divided by `bankPct − charge` and computed the Wh
    /// consumed as `bankWh × (bankPct − charge) / 100`, so the two cancelled
    /// and Calibrate always returned the capacity it started with. `bankPct` is
    /// the engine's estimate, derived from the very capacity being solved for;
    /// it cannot be the baseline.
    static func calibratedCapacity(anchorPct: Double, usedWh: Double, nowPct: Double) -> Double? {
        let drop = anchorPct - nowPct
        guard drop >= 3, usedWh > 0 else { return nil }
        let solved = (usedWh / (drop / 100)).rounded()
        return solved.isFinite && solved > 0 ? solved : nil
    }

    private func calibrate() {
        guard let solved = Self.calibratedCapacity(anchorPct: d.bankAnchorPct,
                                                   usedWh: d.bankUsedWh, nowPct: charge) else { return }
        capacity = solved
        // Re-anchor at the current reading with the solved capacity, so the
        // estimate immediately reflects it.
        onAnchor(charge, solved)
    }

    private func capacityPill(_ title: String, selected: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? DW.cyan : DW.textA(0.7))
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(selected ? DW.cyan.opacity(0.16) : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? DW.cyan.opacity(0.4) : .clear, lineWidth: 0.5))
        }.buttonStyle(.plain)
    }
}
