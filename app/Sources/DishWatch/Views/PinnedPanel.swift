import SwiftUI
import AppKit

/// Hosts the always-on-top CompactWidget in a non-activating floating NSPanel —
/// the right macOS pattern for a glanceable HUD on an accessory app. Bound to
/// `AppState.pinnedWidget`.
@MainActor
final class PinnedPanelController {
    private weak var store: AppState?
    private var panel: NSPanel?

    init(store: AppState) { self.store = store }

    func setVisible(_ on: Bool) {
        // Don't spawn a window during headless snapshot runs.
        if ProcessInfo.processInfo.environment["DISHWATCH_RENDER"] != nil { return }
        // Defer to the next runloop tick: creating an NSHostingView synchronously
        // during SwiftUI App-graph instantiation (AppState.init via @StateObject)
        // triggers an AttributeGraph reentrancy abort.
        DispatchQueue.main.async { [weak self] in
            on ? self?.show() : self?.panel?.orderOut(nil)
        }
    }

    private func show() {
        guard let store else { return }
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 316, height: 360),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered, defer: false)
            p.level = .floating
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = true
            p.backgroundColor = .clear
            p.hasShadow = true

            let host = NSHostingView(rootView: PinnedRoot().environmentObject(store))
            host.sizingOptions = [.intrinsicContentSize]
            p.contentView = host
            p.setContentSize(host.fittingSize)

            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                p.setFrameTopLeftPoint(NSPoint(x: f.maxX - 332, y: f.maxY - 12))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }
}

/// Wrapper so the panel's hosting view re-renders as the store's data changes.
private struct PinnedRoot: View {
    @EnvironmentObject var store: AppState
    var body: some View {
        CompactWidget(d: store.data, onClose: { store.pinnedWidget = false })
            .fixedSize()
            .environment(\.colorScheme, .dark)
    }
}
