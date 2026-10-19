import AppKit
import SwiftUI

/// Screen facts the menu-bar panels size themselves against.
///
/// Extracted from `SettingsView`, which had the only copy, once the status
/// popover needed the same answer. The two panels share one window — settings
/// is swapped into the panel the status popover was first sized into — so
/// having them measure the screen two different ways was a bug waiting for a
/// mixed-display setup.
enum PanelMetrics {
    /// The screen the panel is about to open on.
    ///
    /// **Call this once, at open.** Reading it during `body` is a bug rather
    /// than a style preference: `body` re-evaluates on every poll, so the cap
    /// would track the pointer — open on a 615 pt laptop, move the mouse to a
    /// 1440 pt external, and the next poll asks for a 960 pt panel on a 615 pt
    /// screen. The window server clips that, and a ScrollView does not save it
    /// because it believes it has the room.
    ///
    /// The mouse is the best available answer: the panel appears because the
    /// user just clicked a status item, so the pointer is on the screen whose
    /// menu bar they used. `NSScreen.main` is not usable — an `.accessory` app
    /// usually has no key window — and "shortest attached screen" was safe but
    /// wrong in the ordinary mixed-size case, capping a large external display
    /// to fit a laptop nobody was looking at.
    static var hostScreenHeight: CGFloat {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return s.visibleFrame.height
        }
        return NSScreen.screens.map(\.visibleFrame.height).min() ?? 700
    }
}

/// Keeps the menu-bar panel's window exactly the size of what it is showing.
///
/// `MenuBarExtra(.window)` sizes its window when the panel opens and does not
/// follow the content afterwards. The status panel asks for the screen-height
/// cap until its first measurement lands (see `PopoverView.statusPanel`), so
/// the window opened at the cap — 1060 pt on a 1084 pt display, measured —
/// and stayed there while the content settled to ~620 pt and was drawn
/// centred in it, with a band of empty panel above and below. Settings records
/// the same window refusing to follow a taller sibling.
///
/// So this sets the window's size itself, to the size of the view it sits
/// behind, holding the top edge where it is: the panel hangs from the menu
/// bar, and a resize that kept the origin would move it off the status item.
///
/// Deferred a tick because `layout()` runs inside the window's own layout
/// pass, and resizing the window from there re-enters it.
struct PanelWindowFitter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FitterView() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? FitterView)?.scheduleFit() }

    final class FitterView: NSView {
        private var pending = false

        override func layout() {
            super.layout()
            scheduleFit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleFit()
        }

        func scheduleFit() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                self?.pending = false
                self?.fit()
            }
        }

        private func fit() {
            guard let window, bounds.height > 0, bounds.width > 0 else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            let wantH = bounds.height.rounded(), wantW = bounds.width.rounded()
            guard abs(content.height - wantH) >= 1 || abs(content.width - wantW) >= 1 else { return }
            // Top and left held: the panel hangs from the menu bar with its
            // left edge under the status item (measured: item x 1128, panel
            // x 1129). Settings is wider than the status panel, so width
            // moves too.
            let target = NSRect(x: content.minX, y: content.maxY - wantH,
                                width: wantW, height: wantH)
            window.setFrame(window.frameRect(forContentRect: target), display: true)
            #if DEBUG
            EngineLog.layout.info(
                "panel fit: \(Int(content.width), privacy: .public)x\(Int(content.height), privacy: .public) → \(Int(wantW), privacy: .public)x\(Int(wantH), privacy: .public)")
            #endif
        }
    }
}
