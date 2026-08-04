import SwiftUI

/// Root of the menu-bar popover. Routes to the mains (full-status) or battery
/// (power-hero) layout, mirroring screens A and B of the design.
struct PopoverView: View {
    @EnvironmentObject var store: AppState
    @State private var showSettings = false

    var body: some View {
        // In-panel navigation, NOT a .sheet: the MenuBarExtra(.window) panel is
        // non-activating, so a modal sheet's controls never receive clicks.
        // Swapping the panel's own (clickable) content sidesteps that entirely.
        Group {
            if showSettings {
                SettingsView(onClose: { withAnimation(DW.panelNav) { showSettings = false } })
                    .environmentObject(store)
                    .transition(.opacity)
            } else {
                statusContent
                    .transition(.opacity)
            }
        }
        .frame(width: 392)
        // Vibrancy: blurred desktop behind a translucent gradient tint, not a
        // flat opaque card (per design review).
        .background(.ultraThinMaterial)
        .background(DW.panel(0.82, 0.9))
        .environment(\.colorScheme, .dark)
        .animation(DW.panelNav, value: showSettings)
    }

    @ViewBuilder
    private var statusContent: some View {
        // Battery hero only when the CLI actually has a bank anchored.
        if store.data.onBattery && store.data.bankAnchored {
            BatteryPopover(d: store.data, showSettings: $showSettings)
        } else {
            ConnectedPopover(d: store.data, showSettings: $showSettings)
        }
    }
}
