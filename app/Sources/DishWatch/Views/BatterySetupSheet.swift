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
    var onDone: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var charge: Double
    @State private var capacity: Double
    @State private var showCustom = false
    @State private var customText = ""
    private let presets: [Double] = [27, 67, 100, 230]

    /// Seeded from the live snapshot rather than hardcoded. Reopening "Adjust
    /// bank…" on an anchored 78% / 230 Wh bank used to show 100% / 67 Wh — it
    /// misreported the setting it existed to edit.
    init(d: DishData,
         onAnchor: @escaping (_ pct: Double, _ wh: Double?) -> Void,
         onDone: @escaping () -> Void = {}) {
        self.d = d
        self.onAnchor = onAnchor
        self.onDone = onDone
        _charge = State(initialValue: d.bankAnchored && d.bankPct > 0 ? d.bankPct : 100)
        _capacity = State(initialValue: d.bankWh > 0 ? d.bankWh : 67)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Running on a power bank?").font(.system(size: 17, weight: .bold))
                Text("Tell DishWatch the bank's charge and capacity once — it integrates the dish's live wattage to track % and time remaining.")
                    .font(.system(size: 12.5)).foregroundStyle(DW.textA(0.55)).lineSpacing(2)
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 4)

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
                        capacityPill("\(Int(wh)) Wh", selected: capacity == wh) { capacity = wh }
                    }
                    // Was a bare HStack styled to look exactly like the live
                    // pills beside it — a picture of a button, with no action
                    // and no custom-capacity path anywhere in the app.
                    capacityPill("Custom", selected: showCustom) {
                        showCustom.toggle()
                        if showCustom { customText = String(Int(capacity)) }
                    }
                }
                if showCustom {
                    HStack(spacing: 8) {
                        TextField("Wh", text: $customText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onSubmit(applyCustom)
                        Text("Wh").font(.system(size: 12)).foregroundStyle(DW.textA(0.6))
                        DWButton(title: "Set", action: applyCustom)
                        Spacer()
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

    private func applyCustom() {
        guard let v = Double(customText.trimmingCharacters(in: .whitespaces)), v > 0 else { return }
        capacity = v
        showCustom = false
    }

    /// Calibration needs a prior anchor to measure from and a real drop to
    /// divide by. A 1% drop divided into a Wh figure produces a capacity with
    /// enormous quantization error, so require a few points of movement — the
    /// same reason the CLI's docs tell you to stay in the 30–80% mid-range.
    private var canCalibrate: Bool {
        d.bankAnchored && d.bankWh > 0 && (d.bankPct - charge) >= 3 && consumedWh > 0
    }

    /// Wh drawn since the anchor, from the accumulated total the anchor pinned.
    private var consumedWh: Double {
        max(0, d.bankWh * (d.bankPct - charge) / 100)
    }

    private func calibrate() {
        // Wh_per_full_charge = Wh_consumed / (pct_drop / 100)
        let drop = (d.bankPct - charge) / 100
        guard drop > 0 else { return }
        let solved = (consumedWh / drop).rounded()
        guard solved.isFinite, solved > 0 else { return }
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
