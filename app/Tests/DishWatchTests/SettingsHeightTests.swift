import XCTest
import AppKit
import SwiftUI
@testable import DishWatch

/// The settings panel's height cap, tested at the screen sizes this machine
/// does not have.
///
/// The cap exists for one reason: the panel hangs off the menu bar, and one
/// taller than the display is *clipped* by the window server rather than
/// scrolled, so the controls at the bottom become unreachable. Every assertion
/// here is a restatement of that.
///
/// It is a test rather than a careful reading because the bug it caught was a
/// floor — "never smaller than 600 pt" — that looks obviously safe on a large
/// display and quietly overrides the screen on a small one. Reasoning about
/// this on the machine that has the big screen is how it got in.
final class SettingsHeightTests: XCTestCase {

    /// Everything from a 12" notebook in a scaled mode up to a large desktop
    /// display, as `visibleFrame.height` — already menu-bar and Dock adjusted.
    private let screens: [CGFloat] = [560, 615, 700, 743, 774, 900, 1084, 1440, 2000]

    /// The header the cap has to leave room for, plus nothing else. Kept
    /// deliberately generous against the real ~40 pt: a test that assumed the
    /// exact chrome would pass on a panel with none to spare.
    private let header: CGFloat = 60

    func testPanelNeverOutgrowsItsScreen() {
        for h in screens {
            let panel = SettingsView.contentCap(screenHeight: h) + header
            XCTAssertLessThanOrEqual(panel, h,
                "a \(Int(h))pt screen got a \(Int(panel))pt panel — the window server clips that, it does not scroll it")
        }
    }

    /// The other half: a cap that satisfied the test above by collapsing to
    /// nothing would pass and be useless. So when the *screen* is the binding
    /// constraint, the cap has to actually spend it — no leaving 200 pt of
    /// display unused and scrolling anyway.
    ///
    /// Only while the screen binds. Past that the ceiling takes over and stops
    /// growing, which is correct rather than wasteful: the content is ~885 pt,
    /// so a 2000 pt display capped at 920 is already showing the whole list.
    /// The first version of this test asserted "more than half the screen" and
    /// failed on the large display for exactly that reason — it was measuring
    /// the wrong thing.
    func testTheCapSpendsTheScreenWhileTheScreenIsWhatBinds() {
        for h in screens where h - 120 < 920 {
            let cap = SettingsView.contentCap(screenHeight: h)
            XCTAssertEqual(cap, h - 120, accuracy: 1,
                           "\(Int(h))pt screen should give the list everything but the chrome")
        }
    }

    /// On an ordinary display the list must not scroll at all — "settings about
    /// the size of the main panel" was the whole request.
    ///
    /// The list is *measured*, not quoted. An earlier version of this test
    /// hardcoded 885 pt, which made it a test of a number rather than of the
    /// code: adding one settings row would push the real list past the ceiling
    /// and start it scrolling while the assertion sailed through, and the
    /// ceiling's own doc comment would go stale with it.
    @MainActor
    func testAnOrdinaryDisplayDoesNotScrollAtAll() {
        let store = AppState(provider: SampleProvider(),
                             defaults: UserDefaults(suiteName: "dishwatch.tests.height")!)
        let renderer = ImageRenderer(
            content: SettingsContent(store: store)
                .frame(width: DW.settingsWidth)
                .fixedSize(horizontal: false, vertical: true))
        let listHeight = renderer.nsImage?.size.height ?? 0

        XCTAssertGreaterThan(listHeight, 100, "the settings list failed to lay out at all")
        XCTAssertGreaterThanOrEqual(
            SettingsView.contentCap(screenHeight: 1084), listHeight,
            "the list is \(Int(listHeight))pt and the ceiling is "
            + "\(Int(SettingsView.contentCap(screenHeight: 1084)))pt — it would scroll on an "
            + "ordinary display. Raise the ceiling or shorten the list.")
    }

    /// Monotonic: a bigger screen may never yield a smaller panel. This is what
    /// a floor interacting with a ceiling gets wrong, and the shape is easy to
    /// reintroduce by hand.
    func testABiggerScreenIsNeverASmallerPanel() {
        for (a, b) in zip(screens, screens.dropFirst()) {
            XCTAssertLessThanOrEqual(SettingsView.contentCap(screenHeight: a),
                                     SettingsView.contentCap(screenHeight: b),
                                     "\(Int(a))pt yielded more room than \(Int(b))pt")
        }
    }

    /// Nonsense in, something survivable out. The floor's only remaining job.
    func testAbsurdReadingsDoNotProduceAZeroHeightPanel() {
        for h: CGFloat in [0, -100, 50] {
            XCTAssertGreaterThan(SettingsView.contentCap(screenHeight: h), 0)
        }
    }
}
