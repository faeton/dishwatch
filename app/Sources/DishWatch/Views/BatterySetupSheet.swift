import SwiftUI

/// Battery setup sheet → maps to `sl pb <pct> <wh>`. Pick charge + capacity,
/// optionally calibrate.
struct BatterySetupSheet: View {
    var d: DishData
    @Environment(\.dismiss) private var dismiss
    @State private var charge: Double = 100
    @State private var capacity: Double = 67
    @State private var onBattery = true
    private let presets: [Double] = [27, 67, 100, 230]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Running on a power bank?").font(.system(size: 17, weight: .bold))
                Text("Tell DishWatch the bank's charge and capacity once — it integrates the dish's live wattage to track % and time remaining.")
                    .font(.system(size: 12.5)).foregroundStyle(DW.textA(0.55)).lineSpacing(2)
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 4)

            // power-source toggle
            HStack(spacing: 0) {
                segment("Mains", selected: !onBattery) { onBattery = false }
                segment("Battery", selected: onBattery) { onBattery = true }
            }
            .padding(3).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 18).padding(.top, 16)

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
                    HStack(spacing: 5) {
                        Text("Custom"); Text("›").opacity(0.5)
                    }
                    .font(.system(size: 12)).foregroundStyle(DW.textA(0.7))
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
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
                DWButton(title: "Calibrate")
                Button {
                    // maps to: sl pb \(Int(charge)) \(Int(capacity))
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

    private func segment(_ title: String, selected: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(title)
                .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? DW.cyan : DW.textA(0.55))
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(selected ? DW.cyan.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
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
