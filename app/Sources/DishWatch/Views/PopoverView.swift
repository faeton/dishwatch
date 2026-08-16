import SwiftUI

/// Root of the menu-bar popover. Routes to the mains (full-status) or battery
/// (power-hero) layout, mirroring screens A and B of the design.
struct PopoverView: View {
    @EnvironmentObject var store: AppState
    @State private var showSettings = false
    @State private var showBankSetup = false

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
                statusContent
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
