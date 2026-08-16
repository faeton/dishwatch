import XCTest
@testable import DishWatch

/// The service reading is two enums composed into one line, and every
/// interesting case is a case where it must say *less* than it could.
///
/// Worth testing rather than eyeballing because the failure mode is silent and
/// in the wrong direction: a composition bug here does not crash or blank the
/// panel, it prints a confident sentence about someone's account.
final class ServiceReadingTests: XCTestCase {

    private func data(_ c: ServiceClass, _ m: ServiceMobility) -> DishData {
        var d = DishData()
        d.serviceClass = c
        d.serviceMobility = m
        return d
    }

    func testClassAndMobilityCompose() {
        XCTAssertEqual(data(.consumer, .mobile).serviceLine,
                       "Consumer · cleared to use in motion")
        XCTAssertEqual(data(.businessPlus, .fixed).serviceLine,
                       "Business Plus · one fixed address")
    }

    /// A stationary dish omits `mobilityClass` entirely — it is the zero value
    /// of the wire enum — so class-only is the ordinary case for most dishes,
    /// not an edge one.
    func testClassAloneStandsOnItsOwn() {
        XCTAssertEqual(data(.consumer, .unknown).serviceLine, "Consumer")
    }

    /// The mobility labels are written lower case to trail a class. With no
    /// class in front of one it has to lead, and a lower-case start reads as a
    /// fragment of a sentence that got cut.
    func testMobilityAloneIsCapitalised() {
        XCTAssertEqual(data(.unknown, .nomadic).serviceLine, "Cleared to move")
    }

    /// Nothing known, nothing drawn. The default `DishData` is what an offline
    /// snapshot carries, and inventing a class for it would be the one lie this
    /// whole feature is arranged to avoid.
    func testSilentWhenTheDishSaidNeither() {
        XCTAssertNil(DishData().serviceLine)
        XCTAssertNil(DishData().serviceExplanation)
    }

    /// The caveat is the reason the explanation exists — it survives even when
    /// there is no mobility clause to explain.
    func testExplanationAlwaysCarriesTheBillingCaveat() throws {
        for m in [ServiceMobility.fixed, .nomadic, .mobile, .unknown] {
            let why = try XCTUnwrap(data(.consumer, m).serviceExplanation,
                                    "a known class is enough to owe an explanation")
            XCTAssertTrue(why.contains("not the plan name on your bill"),
                          "\(m) lost the caveat: \(why)")
        }
    }

    /// No label anywhere may name a product. "Roam", "Residential" and the rest
    /// are SKUs; the dish reports a service *class* and is never told which
    /// plan bought it.
    /// Sweeps everything that reaches the screen, not only the enum labels.
    ///
    /// Checking the labels alone would let a later edit put "Roam" into the
    /// composition in `serviceLine` or into the billing caveat and still pass,
    /// under a test whose name promises "no label anywhere".
    func testNoLabelNamesASKU() {
        let sku = ["roam", "residential", "priority", "standard", "unlimited", "mobile priority"]
        var text = [String]()
        for c in [ServiceClass.consumer, .business, .businessPlus, .aviation, .unknown] {
            text.append(c.label)
        }
        for m in [ServiceMobility.fixed, .nomadic, .mobile, .unknown] {
            text.append(m.label)
            text.append(m.explanation)
            // The composed strings too — every combination, since the line and
            // the caveat are assembled rather than looked up.
            for c in [ServiceClass.consumer, .business, .businessPlus, .aviation, .unknown] {
                let d = data(c, m)
                text.append(d.serviceLine ?? "")
                text.append(d.serviceExplanation ?? "")
            }
        }
        for t in text.map({ $0.lowercased() }) where !t.isEmpty {
            for name in sku {
                XCTAssertFalse(t.contains(name), "\"\(t)\" names the SKU \"\(name)\"")
            }
        }
    }

    /// Unknown raw values decode to `.unknown` rather than failing the
    /// snapshot. SpaceX adds to both enums, and a tier this build cannot name
    /// is not a reason to throw away a good poll.
    func testUnrecognisedValuesDegradeToSilence() throws {
        let json = """
        {"schemaVersion":1,"state":"Connected","serviceClass":"orbitalDatacenter","serviceMobility":"warp"}
        """
        let d = try JSONDecoder().decode(DishData.self, from: Data(json.utf8))
        XCTAssertEqual(d.serviceClass, .unknown)
        XCTAssertEqual(d.serviceMobility, .unknown)
        XCTAssertNil(d.serviceLine)
    }
}
