import SwiftUI
import AppKit

/// Settings — pick the menu-bar icon and behaviour. Mirrors the design's
/// Settings panel.
struct SettingsView: View {
    @EnvironmentObject var store: AppState
    /// Returns to the status panel (in-panel navigation, not a window).
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(text: "Menu-bar icon").padding(.bottom, 11)
                    VStack(spacing: 7) {
                        ForEach(IconMode.allCases) { mode in
                            iconRow(mode)
                        }
                    }

                    Divider().background(DW.hairline).padding(.vertical, 16)

                    VStack(spacing: 13) {
                        toggleRow("Show value next to icon", $store.showValueNextToIcon)
                        toggleRow("Pinned widget — always on top", $store.pinnedWidget)
                        toggleRow("Launch at login", $store.launchAtLogin)
                        #if DEBUG
                        toggleRow("Simulate battery (demo)", $store.simulateBattery)
                        #endif
                        HStack {
                            Text("Refresh interval").font(.system(size: 13))
                            Spacer()
                            Picker("", selection: $store.refreshInterval) {
                                ForEach([1, 2, 5, 10, 30, 60], id: \.self) { Text("\($0) s").tag($0) }
                            }
                            .labelsHidden().frame(width: 90)
                        }
                    }

                    Divider().background(DW.hairline).padding(.vertical, 16)

                    // About + Quit
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("DishWatch \(appVersion)").font(.system(size: 11)).foregroundStyle(DW.textA(0.55))
                            Text(store.isLive ? "Live · unofficial Starlink monitor" : "Sample data · install the dishwatch CLI for live")
                                .font(.system(size: 10.5)).foregroundStyle(DW.textA(0.4))
                        }
                        Spacer()
                        DWButton(title: "Quit") { NSApplication.shared.terminate(nil) }
                    }
                }
                .padding(18)
            }
            // Cap height so a long settings list scrolls instead of forcing the
            // MenuBarExtra panel to an unwieldy size.
            .frame(maxHeight: 460)
        }
        .foregroundStyle(DW.text)
        .environment(\.colorScheme, .dark)
    }

    /// Back bar — the only way out of in-panel settings.
    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Back").font(.system(size: 13))
                }
                .foregroundStyle(DW.textA(0.7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Settings").font(.system(size: 13, weight: .semibold)).foregroundStyle(DW.textA(0.85))
            Spacer()
            // Balance the back button so the title stays centered.
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 11)
        .overlay(Divider().background(DW.hairline), alignment: .bottom)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private func iconRow(_ mode: IconMode) -> some View {
        let selected = store.iconMode == mode
        return Button { store.iconMode = mode } label: {
            HStack(spacing: 11) {
                iconPreview(mode)
                Text(mode.rawValue).font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? DW.text : DW.textA(0.75))
                if mode == .auto {
                    Text("battery on bank, else signal").font(.system(size: 12)).foregroundStyle(DW.textA(0.45))
                }
                Spacer()
                ZStack {
                    Circle().fill(selected ? DW.cyan : .clear).frame(width: 16, height: 16)
                    Circle().strokeBorder(selected ? .clear : Color.white.opacity(0.25), lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Color(hex: 0x04121B))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(selected ? DW.cyan.opacity(0.14) : Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? DW.cyan.opacity(0.32) : .clear, lineWidth: 0.5))
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private func iconPreview(_ mode: IconMode) -> some View {
        switch mode {
        case .signalBars: SignalBars(color: DW.cyan, height: 13, barWidth: 2.5, fraction: 0.78)
        case .dishArc:    DishArcGlyph(color: DW.cyan, size: 14)
        case .dataReadout:
            Text("31ms").font(.system(size: 12, weight: .semibold, design: .monospaced))
        case .auto:
            Text("⚡ Auto").font(.system(size: 13)).foregroundStyle(DW.textA(0.75))
        }
    }

    private func toggleRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch).tint(DW.cyan)
        }
    }
}
