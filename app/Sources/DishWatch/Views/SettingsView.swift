import SwiftUI
import AppKit

/// Settings — pick the menu-bar icon, the readout, and behaviour. Mirrors the
/// design's Settings panel.
struct SettingsView: View {
    @EnvironmentObject var store: AppState
    /// Returns to the status panel (in-panel navigation, not a window).
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView { SettingsContent(store: store) }
                // Cap height so a long settings list scrolls instead of forcing
                // the MenuBarExtra panel to an unwieldy size.
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
}

/// Every control on the settings screen, outside the `ScrollView` that hosts it.
///
/// A separate view rather than a computed property on `SettingsView`, and it
/// takes the store explicitly rather than through `@EnvironmentObject`, because
/// the reason it exists is the headless render harness: `ImageRenderer` does not
/// rasterize a ScrollView's contents, so the settings snapshot was a header over
/// an empty page. This is the only screen whose every control lives inside the
/// scroller, which made it the only screen the harness silently never checked —
/// and an environment object is not populated on a view nobody rendered, so
/// reaching in from `Render` needs a real initialiser.
struct SettingsContent: View {
    @ObservedObject var store: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Menu-bar icon").padding(.bottom, 11)
            VStack(spacing: 7) {
                ForEach(IconMode.allCases) { mode in
                    iconRow(mode)
                }
            }

            Divider().background(DW.hairline).padding(.vertical, 16)

            SectionLabel(text: "Menu-bar readout").padding(.bottom, 6)
            preview.padding(.bottom, 11)
            VStack(spacing: 7) {
                ForEach(MenuBarField.allCases) { field in
                    fieldRow(field)
                }
            }

            Divider().background(DW.hairline).padding(.vertical, 16)

            VStack(spacing: 13) {
                toggleRow("Pinned widget — always on top", $store.pinnedWidget)
                toggleRow("Launch at login", $store.launchAtLogin)
                if let err = store.launchAtLoginError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(DW.amber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                    // Was `isLive ? "Live" : "Sample data · install the
                    // dishwatch CLI"`. Both halves were wrong for a shipped
                    // build: `isLive` only means a provider was selected, so it
                    // read "Live" while every poll failed; and the other branch
                    // told a Store user to install a CLI that is not how this
                    // app works.
                    Text(statusLine)
                        .font(.system(size: 10.5)).foregroundStyle(DW.textA(0.4))
                }
                Spacer()
                DWButton(title: "Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(18)
    }

    // MARK: - menu-bar readout

    /// What the bar will look like with the current ticks, drawn with the same
    /// views the bar itself uses and the same live numbers.
    ///
    /// The readout is the one setting whose result is invisible while you are
    /// choosing it: the panel is covering the menu bar it changes. Rendering the
    /// real thing rather than a mock-up also means the preview cannot drift.
    private var preview: some View {
        HStack(spacing: 8) {
            MenuBarIconContent(store: store, ink: DW.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }

    private func fieldRow(_ field: MenuBarField) -> some View {
        let on = store.menuBarFields.contains(field)
        return Button {
            if on { store.menuBarFields.remove(field) } else { store.menuBarFields.insert(field) }
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(on ? DW.cyan : .clear).frame(width: 15, height: 15)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(on ? .clear : Color.white.opacity(0.25), lineWidth: 1.5)
                        .frame(width: 15, height: 15)
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Color(hex: 0x04121B))
                    }
                }
                Text(field.title).font(.system(size: 13, weight: on ? .medium : .regular))
                    .foregroundStyle(on ? DW.text : DW.textA(0.75))
                if let note = field.note {
                    Text(note).font(.system(size: 12)).foregroundStyle(DW.textA(0.45))
                }
                Spacer(minLength: 8)
                // What it currently draws, so the width it costs is legible
                // before the box is ticked rather than after.
                if field == .pingSpark {
                    MenuBarSpark(values: store.data.pingSeries, color: DW.cyan)
                } else if let t = field.text(store.data) {
                    Text(t).font(.system(size: 12)).monospacedDigit().foregroundStyle(DW.textA(0.5))
                } else {
                    // Battery off a bank. An em-dash, not a 0%, which would read
                    // as a flat battery rather than as "nothing to show".
                    Text("—").font(.system(size: 12)).foregroundStyle(DW.textA(0.3))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(on ? DW.cyan.opacity(0.14) : Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(on ? DW.cyan.opacity(0.32) : .clear, lineWidth: 0.5))
        }.buttonStyle(.plain)
    }

    // MARK: - glyph

    private func iconRow(_ mode: IconMode) -> some View {
        let selected = store.iconMode == mode
        return Button { store.iconMode = mode } label: {
            HStack(spacing: 11) {
                iconPreview(mode)
                Text(mode.rawValue).font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? DW.text : DW.textA(0.75))
                if let note = iconNote(mode) {
                    Text(note).font(.system(size: 12)).foregroundStyle(DW.textA(0.45))
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

    private func iconNote(_ mode: IconMode) -> String? {
        switch mode {
        case .auto:    return "battery on bank, else signal"
        case .noGlyph: return "readout only"
        default:       return nil
        }
    }

    @ViewBuilder
    private func iconPreview(_ mode: IconMode) -> some View {
        switch mode {
        case .signalBars: SignalBars(color: DW.cyan, height: 13, barWidth: 2.5, fraction: 0.78)
        case .dishArc:    DishArcGlyph(color: DW.cyan, size: 14)
        // Just the bolt: the row prints `mode.rawValue` right beside this, so
        // spelling the word here rendered "⚡ Auto  Auto  battery on bank…".
        case .auto:
            Text("⚡").font(.system(size: 13)).frame(width: 14)
        case .noGlyph:
            Text("—").font(.system(size: 13)).foregroundStyle(DW.textA(0.4)).frame(width: 14)
        }
    }

    // MARK: - misc

    private func toggleRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch).tint(DW.cyan)
        }
    }

    /// Mirrors the popover footer, so the two never disagree about whether the
    /// app is working.
    private var statusLine: String {
        switch store.quality {
        case .live, .disabled: return "Live · unofficial dish monitor"
        case .loading:         return "Connecting…"
        case .offline:         return "No dish found · unofficial dish monitor"
        case .stale:           return "Not responding · showing the last reading"
        case .sample:          return "Sample data · development build"
        case .brokenInstall:   return "Helper missing · reinstalling should fix it"
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
