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
        //
        // `#if DEBUG` for the same reason every other environment hook in this
        // app has one, and this was the one that did not. `Render` itself is
        // compiled out of a release build, so the *only* thing this line did
        // there was leave "DISHWATCH_RENDER" in a shipped binary and let a
        // stray environment variable suppress a window the user had turned on
        // — a shipped app changing behaviour on an env var, which is precisely
        // what CI's dev-hook guard exists to prevent. It never caught this:
        // that check enumerates hook names by hand and this one was not on the
        // list. It is now, which is what stops the pair from drifting apart
        // again.
        #if DEBUG
        if ProcessInfo.processInfo.environment["DISHWATCH_RENDER"] != nil { return }
        #endif
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
        CompactWidget(d: store.data,
                      onClose: { store.pinnedWidget = false },
                      quality: store.quality)
            .fixedSize()
            .environment(\.colorScheme, .dark)
    }
}
