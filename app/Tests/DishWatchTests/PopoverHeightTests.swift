import XCTest
import AppKit
import SwiftUI
@testable import DishWatch

/// The status panel's height cap, at the screen sizes this machine does not
/// have.
///
/// Same rule as `SettingsHeightTests`, and it is worth stating twice because
/// the status panel is the *taller* of the two and had no cap at all: with the
/// detail row expanded it asks for over 1000 pt, which does not fit the usable
/// height of a 13" notebook. A menu-bar panel that outgrows its screen is
/// clipped by the window server, not scrolled, so everything below the fold —
/// the detail row, the footer, the Pin button — was unreachable.
final class PopoverHeightTests: XCTestCase {

    /// `visibleFrame.height` — already menu-bar and Dock adjusted — from a 12"
    /// notebook in a scaled mode up to a large desktop display.
    private let screens: [CGFloat] = [560, 615, 700, 743, 774, 900, 1084, 1440, 2000]

    func testPanelNeverOutgrowsItsScreen() {
        for h in screens {
            XCTAssertLessThanOrEqual(PopoverView.contentCap(screenHeight: h), h,
                "a \(Int(h))pt screen got a \(Int(PopoverView.contentCap(screenHeight: h)))pt panel — the window server clips that, it does not scroll it")
        }
    }

    /// The other half: a cap that passed the test above by collapsing to
    /// nothing would be useless. When the screen is the binding constraint the
    /// cap has to actually spend it.
    func testCapSpendsTheScreenItIsGiven() {
        for h in screens {
            XCTAssertGreaterThan(PopoverView.contentCap(screenHeight: h), h * 0.9,
                "\(Int(h))pt screen left more than a tenth of the display unused")
        }
    }

    /// No ceiling: the status panel's height is the data's, so a large display
    /// should show all of it rather than scrolling at an arbitrary limit. This
    /// is the one place it deliberately differs from settings.
    func testNoArbitraryCeilingOnLargeDisplays() {
        XCTAssertGreaterThan(PopoverView.contentCap(screenHeight: 1440), 1000)
        XCTAssertGreaterThan(PopoverView.contentCap(screenHeight: 2000), 1500)
    }

    /// A 13" notebook must cap *below* the expanded panel's real height, or the
    /// cap is not doing anything for the case that motivated it.
    func testTheExpandedPanelActuallyScrollsOnASmallNotebook() {
        // ~1043 pt measured from the render harness with the detail row open.
        let expandedPanel: CGFloat = 1043
        XCTAssertLessThan(PopoverView.contentCap(screenHeight: 615), expandedPanel)
        XCTAssertLessThan(PopoverView.contentCap(screenHeight: 774), expandedPanel)
    }

    /// A nonsensical reading must not produce a zero-height panel — but the
    /// floor must stay well below any real display, or it overrides the screen
    /// on a short one. That inversion is exactly how the settings cap regressed.
    func testFloorCannotOverrideARealScreen() {
        XCTAssertEqual(PopoverView.contentCap(screenHeight: 0), 240)
        XCTAssertLessThan(PopoverView.contentCap(screenHeight: 560), 560)
    }
}
