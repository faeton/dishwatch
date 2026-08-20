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

    // MARK: - Metering

    /// The cap clause trails the class the same way the mobility one does, and
    /// comes last: it is a property of the plan, not of the dish's permissions.
    func testMeteredTrailsTheServiceLine() {
        var d = data(.consumer, .mobile)
        d.metered = true
        XCTAssertEqual(d.serviceLine, "Consumer · cleared to use in motion · metered")
    }

    /// A dish can report a cap without reporting a class — `classOfService` has
    /// an explicit UNKNOWN and `mobilityClass` drops its zero value, while
    /// `treatAsMetered` is independent of both. When it leads it has to be
    /// capitalised, like the mobility clause does.
    func testMeteredAloneStillDrawsALine() {
        var d = DishData()
        d.metered = true
        XCTAssertEqual(d.serviceLine, "Metered")
    }

    /// The absent case must stay silent. `treatAsMetered` is omitted from the
    /// wire when false, so an unmetered dish and firmware too old to have the
    /// field are indistinguishable — and neither is grounds for the panel to
    /// state that a connection is uncapped.
    func testUnmeteredClaimsNothing() {
        let d = data(.consumer, .mobile)
        XCTAssertEqual(d.serviceLine, "Consumer · cleared to use in motion")
        let why = d.serviceExplanation ?? ""
        XCTAssertFalse(why.localizedCaseInsensitiveContains("metered"))
    }

    /// The explanation has to say the one thing the dish cannot: it reports
    /// *that* the link is metered and never how much allowance is left. Someone
    /// rationing data on a crossing will read this line as a budget if it does
    /// not say otherwise.
    func testMeteredExplanationRefusesToImplyARemainingAllowance() throws {
        var d = data(.consumer, .mobile)
        d.metered = true
        let why = try XCTUnwrap(d.serviceExplanation)
        XCTAssertTrue(why.localizedCaseInsensitiveContains("metered"))
        XCTAssertTrue(why.localizedCaseInsensitiveContains("does not report how much"))
    }

    // MARK: - Disablement

    /// Every token dashboard.go can emit needs a phrase here, or the panel says
    /// "Disabled" and nothing else for an outage it could have explained.
    func testEveryDisableCaseHasAPhrase() {
        for c in [ServiceDisable.noAccount, .accountDisabled, .tooFarFromServiceAddress,
                  .inOcean, .roamRestricted, .blockedCountry, .blockedArea,
                  .cellDisabled, .dataOverage, .movingTooFast, .aviationFlyoverLimit,
                  .unsupportedVersion, .unknownLocation] {
            XCTAssertFalse(c.label.isEmpty, "\(c) has no phrase")
        }
    }

    /// `.none` is the healthy dish, and it must draw nothing at all — a cause
    /// line on a connected panel is worse than a missing one.
    func testWorkingDishHasNoBlockedReason() {
        XCTAssertNil(DishData().serviceBlockedReason)
        XCTAssertTrue(ServiceDisable.none.label.isEmpty)
    }

    /// The wire tokens, spelled as dashboard.go emits them. This is the pair of
    /// hand-maintained tables either side of the process boundary, so the test
    /// has to name the strings rather than round-trip the enum against itself.
    func testDisableTokensDecodeFromTheWire() throws {
        for (token, want) in [("inOcean", ServiceDisable.inOcean),
                              ("roamRestricted", .roamRestricted),
                              ("dataOverage", .dataOverage),
                              ("movingTooFast", .movingTooFast)] {
            let json = """
            {"schemaVersion":1,"state":"Disabled","serviceDisable":"\(token)"}
            """
            let d = try JSONDecoder().decode(DishData.self, from: Data(json.utf8))
            XCTAssertEqual(d.serviceDisable, want)
            XCTAssertNotNil(d.serviceBlockedReason)
        }
    }

    /// A cause newer than this build degrades to silence without taking the
    /// snapshot with it. The state still reads "Disabled", so the outage is
    /// never concealed — only its reason goes unstated.
    func testUnknownDisableCodeDegradesToSilenceNotFailure() throws {
        let json = """
        {"schemaVersion":1,"state":"Disabled","serviceDisable":"eatenByKraken"}
        """
        let d = try JSONDecoder().decode(DishData.self, from: Data(json.utf8))
        XCTAssertEqual(d.serviceDisable, .none)
        XCTAssertNil(d.serviceBlockedReason)
        XCTAssertEqual(d.state, .disabled)
    }

    /// The cause must not be folded into the hero word. `CompactWidget` and the
    /// menu-bar tooltip both reuse `stateLabel` verbatim in slots sized for one
    /// word, and a clause there truncates mid-sentence.
    func testBlockedReasonStaysOutOfTheStateLabel() {
        var d = DishData()
        d.state = .disabled
        d.serviceDisable = .inOcean
        XCTAssertEqual(d.stateLabel, "Disabled")
        XCTAssertNotNil(d.serviceBlockedReason)
    }
}
