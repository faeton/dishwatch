import SwiftUI

/// Root of the menu-bar popover. Routes to the mains (full-status) or battery
/// (power-hero) layout, mirroring screens A and B of the design.
struct PopoverView: View {
    @EnvironmentObject var store: AppState
    @State private var showSettings = false
    @State private var showBankSetup = false
    /// The status panel's own laid-out height, and the screen it opened on.
    /// See `statusPanel` for what they are for.
    @State private var contentHeight: CGFloat = 0
    @State private var screenHeight: CGFloat = 0

    var body: some View {
        // In-panel navigation, NOT a .sheet: the MenuBarExtra(.window) panel is
        // non-activating, so a modal sheet's controls never receive clicks.
        // Swapping the panel's own (clickable) content sidesteps that entirely.
        //
        // The battery setup screen is routed here for exactly that reason. It
        // was presented with `.sheet` from BatteryPopover, so even once its
        // buttons did something they would not have been clickable — this file
        // already documented the rule the sheet was breaking.
        Group {
            if showSettings {
                SettingsView(onClose: { withAnimation(DW.panelNav) { showSettings = false } })
                    .environmentObject(store)
                    .transition(.opacity)
            } else if showBankSetup {
                BatterySetupSheet(
                    d: store.data,
                    onAnchor: { pct, wh in Task { await store.setBankAnchor(pct: pct, wh: wh) } },
                    onDone: { withAnimation(DW.panelNav) { showBankSetup = false } }
                )
                .transition(.opacity)
            } else {
                statusPanel
                    .transition(.opacity)
            }
        }
        // Settings is wider than the status panel — see DW.settingsWidth. The
        // panel is resized by the window server as the content changes, which
        // is the same mechanism that already handles the popover growing when
        // the detail row expands.
        .frame(width: showSettings ? DW.settingsWidth : DW.panelWidth)
        // Vibrancy: blurred desktop behind a translucent gradient tint, not a
        // flat opaque card (per design review).
        .background(.ultraThinMaterial)
        .background(DW.panel(0.82, 0.9))
        .environment(\.colorScheme, .dark)
        .animation(DW.panelNav, value: showSettings)
        .animation(DW.panelNav, value: showBankSetup)
    }

    /// The status panel, capped so it can never be taller than the display.
    ///
    /// A panel hanging off the menu bar is **clipped** by the window server
    /// when it outgrows the screen, not scrolled — the finding `SettingsView`
    /// records and tests. Settings has had a cap since; the status popover
    /// never did, and it is the taller of the two: expanding the detail row
    /// takes it past 1000 pt, which does not fit the usable height of a 13"
    /// notebook. Everything below the fold — the detail row, the footer, the
    /// Pin button — was simply unreachable there.
    ///
    /// This is also the panel that sizes the shared window, so a status panel
    /// asking for more than the screen is the likeliest explanation for the
    /// resize behaviour `SettingsView` documents as unsettled.
    ///
    /// **The content is always inside the ScrollView; only scrolling is
    /// conditional.** The first version of this made the ScrollView itself
    /// conditional, to keep sparkline scrubbing — a `DragGesture` along a
    /// trace — out of competition with a scroll gesture. It could never engage.
    ///
    /// Measuring `statusContent` with a `GeometryReader` background reports the
    /// height it was *laid out at*, not the height it wants. Outside a scroll
    /// view the panel is already being squeezed by the window, so the probe
    /// reported the squeezed height, which is by definition no greater than the
    /// cap — so `overflows` stayed false, the scroll view never appeared, and
    /// the squeeze continued. A measurement taken downstream of the problem
    /// cannot detect the problem.
    ///
    /// A vertical `ScrollView` proposes `nil` height to its content, so inside
    /// one the probe measures what the content actually wants. `scrollDisabled`
    /// then keeps the gesture out of the way whenever the content fits, which
    /// is the common case and the one the original concern was about.
    ///
    /// This is also what fixes the shrinking text. Squeezed vertically, every
    /// `Text` carrying `minimumScaleFactor` — the spark row's `avg` figures,
    /// the hero's ID, firmware and service lines — gives up font size to fit
    /// the height it was handed. Nothing else on the panel has that modifier,
    /// which is exactly why only those went small when the detail row opened,
    /// and why it read as a font bug rather than a layout one.
    ///
    /// Not verifiable from `Render.snap`: it wraps every view in
    /// `.fixedSize(vertical: true)`, which forces the ideal height and so can
    /// never reproduce a squeeze. Same trap `SettingsView` documents.
    @ViewBuilder
    private var statusPanel: some View {
        let cap = Self.contentCap(screenHeight: screenHeight > 0 ? screenHeight
                                                                 : PanelMetrics.hostScreenHeight)
        // Until the first measurement lands, ask for the cap rather than zero —
        // `min(0, cap)` is a zero-height panel.
        let resolved = contentHeight > 0 ? min(contentHeight, cap) : cap
        ScrollView { statusContent.background(heightProbe) }
            .scrollDisabled(contentHeight > 0 && contentHeight <= cap)
            .frame(height: resolved)
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .onAppear {
                screenHeight = PanelMetrics.hostScreenHeight
            }
    }

    /// Reports the content's laid-out height without affecting the layout.
    private var heightProbe: some View {
        GeometryReader { g in
            Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
        }
    }

    /// The tallest the status panel may be drawn before it starts scrolling.
    ///
    /// A pure function of the screen height, for the same reason
    /// `SettingsView.contentCap` is one: the interesting cases are the displays
    /// this machine does not have, and a floor that looks harmless on a large
    /// screen is exactly how the settings cap regressed — "never smaller than
    /// 600 pt" silently overrode a 615 pt display and asked for a panel the
    /// window server clipped.
    ///
    /// No ceiling, unlike settings. Settings caps at 920 because a settings
    /// list that long is a design problem; the status panel's height is the
    /// data's, and a big display should simply show all of it.
    ///
    /// `visibleFrame` already excludes the menu bar and the Dock, so `chrome`
    /// is only the margin that keeps the panel off the bottom edge.
    static func contentCap(screenHeight: CGFloat) -> CGFloat {
        max(240, screenHeight - chrome)
    }

    private static let chrome: CGFloat = 24

    @ViewBuilder
    private var statusContent: some View {
        // Battery hero only when the CLI actually has a bank anchored.
        if store.data.onBattery && store.data.bankAnchored {
            BatteryPopover(d: store.data, showSettings: $showSettings, showBankSetup: $showBankSetup)
        } else {
            ConnectedPopover(d: store.data, showSettings: $showSettings)
        }
    }
}
