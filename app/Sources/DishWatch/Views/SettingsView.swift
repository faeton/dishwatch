import SwiftUI
import AppKit

/// Settings — pick the menu-bar icon, the readout, and behaviour. Mirrors the
/// design's Settings panel.
struct SettingsView: View {
    @EnvironmentObject var store: AppState
    /// Returns to the status panel (in-panel navigation, not a window).
    var onClose: () -> Void = {}
    /// The settings list's own height, measured from the laid-out content.
    @State private var contentHeight: CGFloat = 0
    /// The host screen's usable height, sampled **once** when the panel opens.
    ///
    /// Not read live, and that distinction is the whole point. `hostScreenHeight`
    /// asks where the pointer is, which is the right question at open time — the
    /// panel exists because the user just clicked a status item — and the wrong
    /// one a second later. `body` re-evaluates on every poll (once a second by
    /// default) and on every settings toggle, so reading it there let the cap
    /// track the mouse: open on a 615 pt laptop with a 495 pt cap, move the
    /// pointer to a 1440 pt external, and the next poll recomputes the cap as
    /// 920 and asks for a ~960 pt panel on a 615 pt screen. The window server
    /// clips that, and the ScrollView does not save it because it believes it
    /// has the room. Both reviewers caught it independently.
    ///
    /// Zero until `onAppear`, which `resolvedHeight` treats as "not measured
    /// yet". `SettingsView` is constructed inside `if showSettings`, so this is
    /// re-sampled every time settings is opened — including onto a different
    /// screen.
    @State private var screenHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                SettingsContent(store: store)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                    })
            }
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            // An explicit height rather than `maxHeight` — but **not** because
            // the ceiling failed to bind. That was the theory, it was wrong, and
            // the correction belongs here rather than in a commit message
            // nobody will reread.
            //
            // Measured with a standalone `NSHostingView`, sweeping the cap:
            //
            //     cap 460 → 500 pt    cap 760 → 800 pt    cap 920 → 956 pt
            //
            // identical under both spellings. So two things are settled. The
            // ceiling *does* bind — a `ScrollView` adopts its content's height
            // beneath it — and `.frame(height:)` is not an improvement on
            // `.frame(maxHeight:)`; a test written to catch a difference passed
            // under its own mutation because there is none. This spelling is
            // kept only because a stated height rests on one less inference,
            // not because it fixed anything.
            //
            // What is *not* settled is the panel. The requested size demonstrably
            // grew by 300 pt and the window on screen did not follow, so the
            // constraint is the host: settings is swapped into the same
            // `MenuBarExtra` panel that was first sized to the status popover
            // (`PopoverView` sets width only), and that window is evidently not
            // resizing to a later, taller sibling. An ideal size from a detached
            // hosting view is not a theory of that window — which is the trap
            // this comment has already fallen into twice.
            //
            // `SettingsPanelProbe` logs asked-versus-granted on every open, so
            // the next move is a measurement of the panel itself.
            //
            // One methodological note worth keeping, since it cost three
            // attempts: `Render.snap` wraps every view in
            // `.fixedSize(vertical: true)`, which forces the ideal height. The
            // harness therefore shows a tall settings panel no matter what this
            // line says, and cannot be used as evidence about the real one.
            .frame(height: resolvedHeight)
        }
        .foregroundStyle(DW.text)
        .environment(\.colorScheme, .dark)
        .onAppear {
            screenHeight = Self.hostScreenHeight
            // `asked` is read inside the probe's own delayed block, not here:
            // at `onAppear` the preference has not landed, so `resolvedHeight`
            // is still the cap rather than the height actually settled on.
            SettingsPanelProbe.report(screen: screenHeight) { resolvedHeight }
        }
    }

    /// Content height, capped — so it scrolls only when it genuinely cannot fit.
    ///
    /// Falls back to the cap until the first measurement lands, which is one
    /// layout pass. Opening slightly tall and settling is the right way round:
    /// the alternative is a panel that opens short and grows, which reads as the
    /// list loading.
    private var resolvedHeight: CGFloat {
        let cap = Self.contentCap(screenHeight: screenHeight > 0 ? screenHeight
                                                                 : Self.hostScreenHeight)
        guard contentHeight > 0 else { return cap }
        return min(contentHeight, cap)
    }

    /// Room reserved above the content: this screen's own header, plus a margin
    /// so the panel does not end flush against the bottom of the display.
    private static let chrome: CGFloat = 120

    /// The tallest the list may be drawn before it starts scrolling.
    ///
    /// Split out as a pure function of the screen height because the interesting
    /// cases are the ones this machine does not have. A floor that reads as
    /// harmless on a 1084 pt display — "never smaller than 600" — silently wins
    /// over the screen-derived value on a small one and asks for a 640 pt panel
    /// on a 615 pt screen, which the window server clips rather than scrolls.
    /// That is the precise failure the cap exists to prevent, reintroduced by
    /// the guard meant to stop a regression. `SettingsHeightTests` covers it.
    ///
    /// So the floor is now well below any real display: it exists only so a
    /// nonsensical reading cannot produce a zero-height panel, never to override
    /// a screen that is genuinely short.
    ///
    /// The ceiling is 920 so that an ordinary display does not scroll at all,
    /// which is what was asked for. It has to clear the settings list's own
    /// height — `SettingsHeightTests` measures that list rather than quoting a
    /// number, so adding a row cannot quietly falsify this paragraph.
    static func contentCap(screenHeight: CGFloat) -> CGFloat {
        max(240, min(920, screenHeight - chrome))
    }

    /// The screen the panel is about to open on.
    ///
    /// **Call this once, at open.** See `screenHeight` for why reading it during
    /// `body` is a bug rather than a style preference.
    ///
    /// The mouse is the best available answer: the panel appears because the
    /// user just clicked a status item, so the pointer is on the screen whose
    /// menu bar they used. `NSScreen.main` is not usable here — an `.accessory`
    /// app usually has no key window — and the previous "shortest attached
    /// screen" was safe but wrong in the ordinary mixed-size case, capping a
    /// large external display to fit a laptop panel nobody was looking at.
    ///
    /// The fallback keeps that conservatism for the case where the pointer is
    /// on no screen at all.
    private static var hostScreenHeight: CGFloat {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return s.visibleFrame.height
        }
        return NSScreen.screens.map(\.visibleFrame.height).min() ?? 700
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

/// Logs the height the settings list asked for against the height the panel
/// window was actually given.
///
/// Note what the two numbers are, because they are not the same quantity: the
/// asked figure is the scroller's height, and the granted one is a whole
/// window including this screen's header and any panel chrome. A constant
/// difference between them is expected; a *large* one is the finding.
///
/// This exists because three attempts at making settings taller were all
/// reasoned from the wrong evidence. The render harness wraps every view in
/// `.fixedSize(vertical: true)`, so it showed the tall panel each time and
/// proved nothing about the real one; and `maxHeight` versus an explicit
/// `height` turns out to report identical sizes, so that theory was wrong too.
/// Nobody had measured the panel the system grants.
///
/// `os_log` rather than a file: the app is sandboxed, and its stdout goes
/// nowhere a developer will look. Read it back with
///
///     log show --last 10m --predicate 'subsystem == "com.dishwatch"'
///
/// DEBUG only — a shipped build has no reason to narrate its own layout.
enum SettingsPanelProbe {
    static func report(screen: CGFloat, asked: @escaping () -> CGFloat) {
        #if DEBUG
        // A beat after appearing, so the panel has been sized and placed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let asked = asked()
            // The *menu-bar panel*, not merely the tallest window. Taking the
            // tallest meant the pinned widget — or any stray debug window —
            // could be reported as the settings panel, which is worse than no
            // measurement: it looks like data. The panel is the visible window
            // whose width matches what settings asked for; the pinned widget is
            // a different width, and the status popover is not on screen while
            // settings is.
            let granted = NSApp.windows
                .filter { $0.isVisible && abs($0.frame.width - DW.settingsWidth) < 1 }
                .map(\.frame)
                .max(by: { $0.height < $1.height })
            let size = granted.map { "\(Int($0.width))x\(Int($0.height)) at y=\(Int($0.origin.y))" }
                ?? "no visible window"
            EngineLog.layout.info(
                "settings panel: asked \(Int(asked), privacy: .public)pt (screen \(Int(screen), privacy: .public)pt) → granted \(size, privacy: .public)")
        }
        #endif
    }
}

/// Carries the settings list's laid-out height up to the view that sizes the
/// panel. `max` rather than "last one wins" so a stray zero from a view still
/// being laid out cannot collapse the panel.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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

    /// The whole build identity, not just the marketing version.
    ///
    /// This used to be `CFBundleShortVersionString` alone, which is the one
    /// string that cannot answer "which build is this?" — it is `git describe`
    /// stripped to dotted digits, so every bundle cut from tag v0.2.7 reports
    /// `0.2.7` whether it came off the DMG or out of someone's `.build`
    /// directory. See BuildInfo.
    private var appVersion: String {
        BuildInfo.main.detailLabel
    }
}
