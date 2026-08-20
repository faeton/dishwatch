import XCTest
@testable import DishWatch

/// The country badge is one string built from a free-text wire field, and the
/// failure mode is not a crash — it is a panel confidently flying the wrong
/// flag, or a row of indicator glyphs nobody can read.
final class CountryBadgeTests: XCTestCase {

    private func data(_ code: String) -> DishData {
        var d = DishData()
        d.countryCode = code
        return d
    }

    func testFlagComposesFromRegionalIndicators() {
        XCTAssertEqual(DishData.flag(for: "US"), "🇺🇸")
        XCTAssertEqual(DishData.flag(for: "GL"), "🇬🇱")
        XCTAssertEqual(DishData.flag(for: "UA"), "🇺🇦")
    }

    /// The dish sends the code upper case, but nothing on the wire promises it
    /// and the offset arithmetic is defined from 'A'. Lower case must not fall
    /// off the end of the range into unrelated scalars.
    func testLowerCaseIsAccepted() {
        XCTAssertEqual(DishData.flag(for: "gl"), "🇬🇱")
        XCTAssertEqual(data("gl").countryBadge, "🇬🇱 GL")
    }

    /// Anything that is not exactly two ASCII letters has no flag. "" is the
    /// ordinary case — firmware that omits the field, and every offline
    /// snapshot — and a longer token is what a future firmware might send
    /// instead of leaving it blank.
    func testNonCodesGetNoFlag() {
        for junk in ["", "U", "USA", "UNKNOWN", "12", "U1", "  ", "🇺🇸"] {
            XCTAssertNil(DishData.flag(for: junk), "\(junk) should not compose a flag")
            XCTAssertNil(data(junk).countryBadge, "\(junk) should draw nothing")
        }
    }

    /// Nothing known, nothing drawn — the same rule `serviceLine` follows, and
    /// for the same reason: the panel never guesses a fact about the dish.
    func testSilentWhenTheDishSaidNothing() {
        XCTAssertNil(DishData().countryBadge)
    }

    /// The code survives beside the flag. Several flags are near-identical at
    /// 12.5 pt and a few regions have no glyph at all, so the letters are the
    /// half that always reads.
    func testBadgeKeepsTheCode() {
        XCTAssertEqual(data("GL").countryBadge, "🇬🇱 GL")
        XCTAssertEqual(data("GB").countryBadge, "🇬🇧 GB")
    }

    /// The tooltip's whole job is to say what the reading is *not*. Someone
    /// reading a country in a network app will otherwise assume it is where
    /// their traffic exits, which this field does not claim.
    func testHelpDisclaimsIPAndGPS() {
        let help = data("GL").countryHelp
        XCTAssertTrue(help.contains("not a lookup of your IP address"), help)
        XCTAssertTrue(help.contains("not derived from GPS"), help)
        XCTAssertTrue(help.contains("(GL)"), help)
    }

    /// An unassigned code falls back to the bare code — and, crucially, does
    /// not name a country. `localizedString(forRegionCode:)` answers the
    /// localized placeholder rather than nil, so the unguarded version of this
    /// read "Unknown Region (ZZ) — the country the dish reports for itself".
    func testHelpFallsBackToTheBareCodeWithoutInventingAName() {
        let help = data("ZZ").countryHelp
        XCTAssertTrue(help.hasPrefix("ZZ — "), help)
        XCTAssertFalse(help.contains("Unknown Region"), help)
        XCTAssertNil(DishData.regionName("ZZ"))
    }

    /// The membership gate must not cost real countries their names — it is
    /// consulted before every lookup.
    func testKnownRegionsKeepTheirNames() {
        XCTAssertEqual(DishData.regionName("GL"), "Greenland")
        XCTAssertEqual(DishData.regionName("UA"), "Ukraine")
    }

    /// The field is additive, so an older helper that never sends it must still
    /// decode — the strict half of the decoder is `schemaVersion` and `state`,
    /// and this is not either of them.
    func testDecodesAbsentWithoutFailingTheSnapshot() throws {
        let json = #"{"schemaVersion":1,"state":"Connected","boots":3}"#
        let d = try JSONDecoder().decode(DishData.self, from: Data(json.utf8))
        XCTAssertEqual(d.countryCode, "")
        XCTAssertNil(d.countryBadge)
    }

    func testDecodesFromTheWire() throws {
        let json = #"{"schemaVersion":1,"state":"Connected","countryCode":"GL"}"#
        let d = try JSONDecoder().decode(DishData.self, from: Data(json.utf8))
        XCTAssertEqual(d.countryBadge, "🇬🇱 GL")
    }
}

/// The aim reading is two angles that read as a coordinate unless the panel
/// says otherwise. These pin the wording and the arithmetic that say it.
final class AimReadingTests: XCTestCase {

    /// The dish reports azimuth as −180…180; a compass has no negative bearings
    /// and `-176°` is the same direction as `184°`.
    func testCompassPointNormalisesNegativeBearings() {
        XCTAssertEqual(DishData.compassPoint(-176), "S")
        XCTAssertEqual(DishData.compassPoint(184), "S")
        XCTAssertEqual(DishData.compassPoint(0), "N")
        XCTAssertEqual(DishData.compassPoint(90), "E")
        XCTAssertEqual(DishData.compassPoint(-90), "W")
    }

    /// 360 and 0 are the same direction, and the wrap must not index past the
    /// end of the table.
    func testCompassPointWrapsAtTheSeam() {
        XCTAssertEqual(DishData.compassPoint(360), "N")
        XCTAssertEqual(DishData.compassPoint(359), "N")
        XCTAssertEqual(DishData.compassPoint(720), "N")
        XCTAssertEqual(DishData.compassPoint(-0.4), "N")
    }

    /// Sixteen points, so a label never disagrees with the degrees beside it by
    /// more than 11°.
    func testSixteenPointsNotEight() {
        XCTAssertEqual(DishData.compassPoint(22.5), "NNE")
        XCTAssertEqual(DishData.compassPoint(247.5), "WSW")
    }

    func testNonFiniteBearingSaysNothing() {
        XCTAssertEqual(DishData.compassPoint(.nan), "")
        XCTAssertEqual(DishData.compassPoint(.infinity), "")
    }

    /// The explanation's job is to close off the reading the numbers invite.
    func testAimExplanationDeniesBeingAPosition() {
        let why = DishData().aimExplanation
        XCTAssertTrue(why.contains("not where it is"), why)
        XCTAssertTrue(why.contains("never the position itself"), why)
    }
}
