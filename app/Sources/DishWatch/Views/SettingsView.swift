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
                .frame(maxHeight: Self.maxContentHeight)
        }
        .foregroundStyle(DW.text)
        .environment(\.colorScheme, .dark)
    }

    /// How tall the scroller may grow before it starts scrolling.
    ///
    /// There has to be a cap: the panel hangs off the menu bar, and one taller
    /// than the screen is *clipped* by the window server rather than scrolled —
    /// the controls at the bottom become unreachable, which is worse than a
    /// scrollbar. But the cap used to be a flat 460 pt, under half the height of
    /// an ordinary display, so a list of a dozen controls scrolled on a screen
    /// with room for all of them twice over.
    ///
    /// Derived from the *shortest* attached screen, not `NSScreen.main`: an
    /// `.accessory` app usually has no key window, so `main` is nil or names the
    /// wrong display, and the panel opens on whichever bar was clicked. Erring
    /// short costs a scrollbar; erring tall costs unreachable buttons.
    ///
    /// Floored at the old 460 so a small or oddly-reported display cannot make
    /// this a regression.
    static var maxContentHeight: CGFloat {
        let shortest = NSScreen.screens.map(\.visibleFrame.height).min() ?? 700
        return max(460, min(760, shortest - 140))
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
            // Belongs to the readout, not to the app's general behaviour: it
            // changes how the ticked fields above are drawn, and the preview
            // that answers it is directly above. Below the next divider it
            // would be a bar setting filed under "Pinned widget" and "Launch at
            // login", with the thing it affects scrolled off.
            toggleRow("Colour the ↓↑ figures", $store.colorThroughput,
                      note: "the bar stops matching light/dark by itself")
                .padding(.top, 13)

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
            // `darkBar: true` because this preview sits on the dark panel, not
            // on the user's actual menu bar. It shows which figures are
            // coloured, not which shade they will take in a light bar — the
            // panel cannot honestly show that, and picking the light-bar hues
            // here would misrepresent them against this background.
            MenuBarIconContent(store: store, ink: DW.text,
                               tinted: store.colorThroughput, darkBar: true)
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

    /// `note` is for a consequence the title cannot carry without becoming a
    /// sentence — the same job the grey notes do beside the readout fields.
    private func toggleRow(_ title: String, _ binding: Binding<Bool>,
                           note: String? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            if let note {
                Text(note).font(.system(size: 12)).foregroundStyle(DW.textA(0.45))
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
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
