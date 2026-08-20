import XCTest
@testable import DishWatch

/// The uptime readout used to be `%.1f h`, which spent its only decimal on the
/// least useful end of the range — "0.1 h" six minutes after a reboot, "504.0 h"
/// after three weeks. The ladder that replaced it makes two judgement calls that
/// are invisible in the code and obvious on screen, so both are pinned here:
/// when the minor unit is dropped, and where each unit hands over to the next.
///
/// Mirrors `TestUptimeDur` in internal/state — the CLI header and this panel
/// must not drift apart.
final class UptimeFormatTests: XCTestCase {

    private let min: Int64 = 60
    private let hour: Int64 = 3600
    private let day: Int64 = 86_400

    private func fmt(_ s: Int64) -> String { ConnectedPopover.uptime(s) }

    func testSecondsAndMinutes() {
        XCTAssertEqual(fmt(-5), "0s", "negative uptime is clamped, not rendered")
        XCTAssertEqual(fmt(0), "0s", "the case '0.0h' could not tell from six minutes")
        XCTAssertEqual(fmt(45), "45s")
        XCTAssertEqual(fmt(59), "59s")
        // Seconds never pair with minutes — they churn on every refresh.
        XCTAssertEqual(fmt(min), "1m")
        XCTAssertEqual(fmt(6 * min), "6m")
        XCTAssertEqual(fmt(59 * min), "59m")
    }

    func testHoursCollapseAtDoubleDigits() {
        XCTAssertEqual(fmt(hour), "1h", "a zero minor unit is dropped")
        XCTAssertEqual(fmt(hour + 5 * min), "1h5m")
        XCTAssertEqual(fmt(9 * hour + 59 * min), "9h59m")
        XCTAssertEqual(fmt(10 * hour), "10h")
        XCTAssertEqual(fmt(13 * hour + 42 * min), "13h", "minutes drop once hours reach two digits")
        XCTAssertEqual(fmt(23 * hour + 59 * min), "23h")
    }

    func testDaysMonthsYears() {
        XCTAssertEqual(fmt(day), "1d")
        XCTAssertEqual(fmt(3 * day + 4 * hour), "3d4h")
        XCTAssertEqual(fmt(9 * day + 23 * hour), "9d23h")
        XCTAssertEqual(fmt(10 * day + 5 * hour), "10d")
        XCTAssertEqual(fmt(29 * day + 23 * hour), "29d")
        XCTAssertEqual(fmt(30 * day), "1mo")
        XCTAssertEqual(fmt(44 * day), "1mo14d")
        XCTAssertEqual(fmt(300 * day), "10mo")
        XCTAssertEqual(fmt(365 * day), "1y")
        XCTAssertEqual(fmt(400 * day), "1y1mo")
    }

    /// The wire carries hours as a float; the readout needs seconds. A dish that
    /// booted a minute ago has to survive the round trip, which is the whole
    /// reason `uptimeSeconds` exists rather than a widened schema.
    func testUptimeSecondsRecoveredFromWireHours() {
        var d = DishData()
        d.uptimeHours = 0
        XCTAssertEqual(d.uptimeSeconds, 0)
        d.uptimeHours = 45.0 / 3600
        XCTAssertEqual(d.uptimeSeconds, 45)
        d.uptimeHours = 0.1
        XCTAssertEqual(d.uptimeSeconds, 360)
        XCTAssertEqual(fmt(d.uptimeSeconds), "6m", "the reading that used to render as 0.1 h")
        d.uptimeHours = 7.3
        XCTAssertEqual(fmt(d.uptimeSeconds), "7h18m")
    }

    /// `dur` is the shared span format and keeps both units at every size.
    /// Collapsing the two would quietly change the sparkline labels.
    func testUptimeIsDistinctFromDur() {
        let s = 13 * hour + 42 * min
        XCTAssertEqual(ConnectedPopover.dur(s), "13h 42m")
        XCTAssertEqual(fmt(s), "13h")
    }
}
