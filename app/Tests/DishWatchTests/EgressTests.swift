import XCTest
@testable import DishWatch

/// The exit reading is assembled from a third-party JSON document nobody in
/// this repo controls, and every failure mode is the same shape: the panel
/// states something confident that is not true. A renamed key must cost one
/// line of the row, an error page served with a 200 must be a failure rather
/// than a blank reading drawn as fact, and a reverse-DNS name from a network
/// that is not Starlink must never be printed as a Starlink ground station.
final class EgressTests: XCTestCase {

    /// Captured from `curl https://ip.unt1.com/json -4`. Trimmed of the fields
    /// the app does not read, but not otherwise reshaped — the point of a
    /// fixture is that it is the real document.
    private let v4 = Data("""
    {
      "ip": "217.142.20.123",
      "version": "v4",
      "country": "GB",
      "asn": 14593,
      "asorg": "SPACEX-STARLINK - Space Exploration Technologies Corporation, US",
      "prefix": "217.142.20.0/23",
      "rir": "ripencc",
      "reverse": "customer.lndngbr1.isp.starlink.com",
      "vpn": { "vpn": false },
      "colo": "LHR"
    }
    """.utf8)

    /// A real answer that carried **no `reverse` key at all**.
    ///
    /// Not a hypothetical, and the cause is known: the reflector resolves the
    /// PTR out of a cache it fills asynchronously, so the *first* lookup of an
    /// address answers without one and the next answers with it. Measured, both
    /// families, three rounds — it is a cold-cache miss, not a property of
    /// IPv6. A user who checks once and comes back tomorrow is exactly the
    /// person who hits it.
    ///
    /// So the PoP is a field that can be absent from any lookup, and a decoder
    /// that required it would fail intermittently — the worst way for this to
    /// break, since it would look like the service being down.
    private let v6 = Data("""
    {
      "ip": "2a0d:3341:b715:7510:bc92:6b3d:b7db:6e7f",
      "version": "v6",
      "country": "GB",
      "asn": 14593,
      "asorg": "SPACEX-STARLINK - Space Exploration Technologies Corporation, US",
      "vpn": { "vpn": false }
    }
    """.utf8)

    func testDecodesTheRealIPv4Answer() throws {
        let e = try EgressLookup.decode(v4)
        XCTAssertEqual(e.ip, "217.142.20.123")
        XCTAssertEqual(e.family, "v4")
        XCTAssertEqual(e.countryCode, "GB")
        XCTAssertEqual(e.asn, 14593)
        XCTAssertTrue(e.isStarlink)
        XCTAssertFalse(e.viaVPN)
        XCTAssertEqual(e.badge, "🇬🇧 GB")
        XCTAssertEqual(e.pop, "lndngbr1")
        XCTAssertEqual(e.summary, "🇬🇧 GB · Starlink · lndngbr1")
        XCTAssertEqual(e.detail, "217.142.20.123 · AS14593 · IPv4")
        XCTAssertNil(e.caution, "an ordinary Starlink exit has nothing to warn about")
    }

    func testDecodesIPv6WithoutAReverseName() throws {
        let e = try EgressLookup.decode(v6)
        XCTAssertEqual(e.family, "v6")
        XCTAssertNil(e.reverse)
        XCTAssertNil(e.pop)
        XCTAssertEqual(e.summary, "🇬🇧 GB · Starlink", "the PoP drops out; the rest stands")
        XCTAssertEqual(e.detail, "2a0d:3341:b715:7510:bc92:6b3d:b7db:6e7f · AS14593 · IPv6")
    }

    /// A key the service renames or stops sending must cost exactly the line it
    /// feeds. The address is the one field without which there is no reading at
    /// all, and it is checked separately below.
    func testMissingFieldsDegradeOneLineAtATime() throws {
        let e = try EgressLookup.decode(Data(#"{"ip":"203.0.113.9"}"#.utf8))
        XCTAssertEqual(e.ip, "203.0.113.9")
        XCTAssertNil(e.badge, "no country means no flag, not a blank one")
        XCTAssertEqual(e.asn, 0)
        XCTAssertFalse(e.isStarlink)
        XCTAssertEqual(e.summary, "unknown network")
        XCTAssertEqual(e.detail, "203.0.113.9")
        XCTAssertNil(e.caution, "an unknown AS is not evidence of anything, so it must not accuse")
    }

    /// The failure this guard exists for: a captive portal, a proxy error page
    /// or an outage page served as JSON with a 200. Without the check those
    /// decode into an all-empty `Egress` and the panel draws "unknown network"
    /// as if it had asked and been told.
    func testAnAnswerWithNoAddressIsAFailure() {
        for body in [#"{}"#, #"{"error":"rate limited"}"#, #"{"ip":""}"#] {
            XCTAssertThrowsError(try EgressLookup.decode(Data(body.utf8)), body) { err in
                XCTAssertEqual(err as? EgressError, .noAddress)
            }
        }
    }

    func testNonJSONIsAFailureRatherThanAnEmptyReading() {
        for body in ["<html><body>502 Bad Gateway</body></html>", "", "217.142.20.123"] {
            XCTAssertThrowsError(try EgressLookup.decode(Data(body.utf8)), body) { err in
                XCTAssertEqual(err as? EgressError, .notJSON)
            }
        }
    }

    // MARK: - the PoP name

    /// `customer.lndngbr1.isp.starlink.com` is the only shape whose second
    /// label means a ground station. Anything else is another operator's
    /// naming scheme, and printing a label out of it would put an invented
    /// place name on the panel — the same failure the country badge refuses.
    func testPopIsReadOnlyFromStarlinkReverseNames() {
        func pop(_ reverse: String?) -> String? {
            var e = Egress(); e.reverse = reverse; return e.pop
        }
        XCTAssertEqual(pop("customer.lndngbr1.isp.starlink.com"), "lndngbr1")
        XCTAssertEqual(pop("CUSTOMER.SEATTLEWA1.ISP.STARLINK.COM"), "seattlewa1")
        XCTAssertNil(pop(nil))
        XCTAssertNil(pop("host-82-132-44-9.mobileisp.example.net"))
        XCTAssertNil(pop("isp.starlink.com"))
        XCTAssertNil(pop("customer.isp.starlink.com"), "no label where the PoP should be")
        XCTAssertNil(pop("evil.isp.starlink.com.attacker.example"),
                     "the suffix has to end the name, not merely appear in it")
    }

    // MARK: - the operator's name

    /// `asorg` is a registry field, not a caption. Left whole it is 62
    /// characters and wraps the row twice.
    func testOperatorNameIsShortEnoughToDraw() {
        func name(_ asn: Int, _ org: String) -> String {
            var e = Egress(); e.asn = asn; e.asOrg = org; return e.operatorName
        }
        XCTAssertEqual(name(14593, "SPACEX-STARLINK - Space Exploration Technologies Corporation, US"),
                       "Starlink", "the one name worth spelling out")
        XCTAssertEqual(name(5378, "VODAFONE-LTD - Vodafone Limited, GB"), "VODAFONE-LTD")
        XCTAssertEqual(name(2856, "British Telecommunications PLC, GB"),
                       "British Telecommunications…")
        XCTAssertEqual(name(64500, ""), "AS64500", "no name at all is still an identity")
        XCTAssertEqual(name(0, ""), "unknown network")
        for org in ["SPACEX-STARLINK - Space Exploration Technologies Corporation, US",
                    "British Telecommunications PLC, GB",
                    "A-VERY-LONG-REGISTRY-HANDLE-THAT-KEEPS-GOING - Someone, XX"] {
            XCTAssertLessThanOrEqual(name(64500, org).count, 29, org)
        }
    }

    // MARK: - the sentence that interrupts

    /// The whole reason the feature earns a row: a healthy dish on screen and a
    /// Mac whose packets are leaving through something else.
    func testTrafficLeavingByAnotherNetworkSaysSo() throws {
        var e = try EgressLookup.decode(v4)
        e.asn = 5378
        e.asOrg = "VODAFONE-LTD - Vodafone Limited, GB"
        let caution = try XCTUnwrap(e.caution)
        XCTAssertTrue(caution.contains("not routing through the dish"))
        XCTAssertTrue(caution.contains("VODAFONE-LTD"))
    }

    func testAVPNExitIsCalledAVPN() throws {
        var e = try EgressLookup.decode(v4)
        e.viaVPN = true
        XCTAssertEqual(e.caution?.contains("VPN"), true)
    }

    /// Order matters: a non-Starlink VPN exit gets the routing sentence, which
    /// is the more useful of the two — it explains why every number above the
    /// row describes a link this Mac is not using.
    func testRoutingOutranksTheVPNNote() throws {
        var e = try EgressLookup.decode(v4)
        e.asn = 60068
        e.asOrg = "CDN77 - DataCamp Limited, GB"
        e.viaVPN = true
        XCTAssertEqual(e.caution?.contains("not routing through the dish"), true)
    }

    /// A GeoIP database can answer a code ISO does not assign, exactly as
    /// firmware can, and the exit badge has to treat it the way the country
    /// badge four lines above it does — or one row draws `ZZ` while the other
    /// draws nothing for the same value.
    func testTheBadgeFollowsTheSameRulesAsTheCountryRow() {
        func badge(_ code: String) -> String? {
            var e = Egress(); e.ip = "203.0.113.9"; e.countryCode = code; return e.badge
        }
        XCTAssertEqual(badge("gb"), "🇬🇧 GB")
        XCTAssertEqual(badge("XZ"), "🌊 XZ", "international waters has a picture and is not a country")
        XCTAssertEqual(badge("ZZ"), "ZZ", "no glyph is not a reason to drop the reading")
        for junk in ["", "GBR", "g", "12", "  "] {
            XCTAssertNil(badge(junk), junk)
        }
        // And the two rows agree, whatever the rules become.
        for code in ["GB", "XZ", "ZZ", "", "GBR"] {
            var d = DishData(); d.countryCode = code
            var e = Egress(); e.ip = "203.0.113.9"; e.countryCode = code
            XCTAssertEqual(e.badge, d.countryBadge, code)
        }
    }

    // MARK: - the endpoint

    func testEndpointDefaultsToTheServiceAndAcceptsOnlyHTTPSOverrides() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "egress-endpoint-tests"))
        d.removePersistentDomain(forName: "egress-endpoint-tests")
        XCTAssertEqual(EgressLookup.endpoint(d).absoluteString, EgressLookup.defaultEndpoint)

        d.set("https://example.test/json", forKey: "egressEndpoint")
        XCTAssertEqual(EgressLookup.endpoint(d).absoluteString, "https://example.test/json")

        // An override is an escape hatch for an outage, not a way to talk a
        // user's address out over plain HTTP.
        for bad in ["http://example.test/json", "ftp://example.test", "not a url at all"] {
            d.set(bad, forKey: "egressEndpoint")
            XCTAssertEqual(EgressLookup.endpoint(d).absoluteString, EgressLookup.defaultEndpoint, bad)
        }
        d.removePersistentDomain(forName: "egress-endpoint-tests")
    }

    /// The host in the on-screen disclosure and the host in the request come
    /// from the same place. If they can differ, the consent text is a guess.
    func testTheDisclosedHostIsTheHostContacted() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "egress-host-tests"))
        d.removePersistentDomain(forName: "egress-host-tests")
        XCTAssertEqual(EgressLookup.displayHost(EgressLookup.endpoint(d)), "ip.unt1.com")
        d.set("https://reflector.example.test/json", forKey: "egressEndpoint")
        XCTAssertEqual(EgressLookup.displayHost(EgressLookup.endpoint(d)), "reflector.example.test")
        d.removePersistentDomain(forName: "egress-host-tests")
    }
}
