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
