import XCTest
@testable import DishWatch

/// The `Observed` footer is the app's honesty claim about long-window link
/// quality, so its decode is the one place in `DishData` that must fail closed.
/// These pin that: anything short of a complete, plausible block yields `nil`,
/// and `nil` is what the view gates on.
final class ObservedStatsTests: XCTestCase {

    /// A complete block, well past the readiness threshold.
    private let full: [String: Any] = [
        "obsSeconds": 8040, "obsCoverage": 0.94,
        "sessPingAvg": 29.0, "sessCleanPct": 92.0,
        "sessDegradedPct": 6.0, "sessDarkPct": 2.0,
        "sessOutages": 11, "sessOutageSeconds": 143, "sessLongestOutage": 58,
        "sessDownPeak": 186.0, "sessUpPeak": 41.0,
        "sessDownBytes": 4.2e9, "sessUpBytes": 0.6e9,
        "sessPowerAvg": 23.8, "sessPowerPeak": 48.1, "sessEnergyWh": 53.2,
    ]

    /// Every payload carries the current schema version and a state, because
    /// both are strict now — a decode is expected to fail without them, and
    /// these tests are about the *Observed block*, not about that.
    private func decode(_ payload: [String: Any]) throws -> DishData {
        var body: [String: Any] = ["schemaVersion": DishData.expectedSchema, "state": "Connected"]
        body.merge(payload) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: body)
        return try JSONDecoder().decode(DishData.self, from: data)
    }

    func testCompleteBlockDecodes() throws {
        let d = try decode(full.merging(["state": "Connected"]) { a, _ in a })
        let o = try XCTUnwrap(d.observed)
        XCTAssertEqual(o.seconds, 8040)
        XCTAssertEqual(o.pingAvg, 29)
        XCTAssertEqual(o.outages, 11)
        XCTAssertEqual(o.downPeak, 186)
        XCTAssertEqual(o.powerPeak, 48.1)
    }

    /// The case per-field zero defaults would have missed, and the reason this
    /// block decodes atomically at all: `obsSeconds` is present and real, so a
    /// resilient decoder renders a footer — with a fabricated `peak ↓0` in it.
    func testOneMissingKeyDropsTheWholeBlock() throws {
        var payload = full
        payload.removeValue(forKey: "sessDownPeak")
        let d = try decode(payload)
        XCTAssertNil(d.observed, "a partial block must not render a footer")
    }

    /// Every key individually — no single field may be optional by accident.
    func testEveryKeyIsRequired() throws {
        for key in full.keys {
            var payload = full
            payload.removeValue(forKey: key)
            let d = try decode(payload)
            XCTAssertNil(d.observed, "dropping \(key) must drop the whole block")
        }
    }

    /// An older CLI that predates the session accumulator emits none of it.
    func testAbsentBlockIsNil() throws {
        let d = try decode(["state": "Connected", "pingMs": 17.6, "upMbps": 0.4])
        XCTAssertNil(d.observed)
    }

    /// Zeros across the block are the CLI's "not enough data yet" contract
    /// (< 120 samples), not statistics. Cold start hides the row.
    func testBelowReadinessThresholdIsNil() throws {
        var payload = full
        for k in payload.keys { payload[k] = 0 }
        XCTAssertNil(try decode(payload).observed)

        payload = full
        payload["obsSeconds"] = ObservedStats.minSeconds - 1
        XCTAssertNil(try decode(payload).observed, "119 s is still cold")

        payload["obsSeconds"] = ObservedStats.minSeconds
        XCTAssertNotNil(try decode(payload).observed, "120 s is the threshold, inclusive")
    }

    /// Type drift is drift too — a field that turns into a string must not
    /// silently become a zero.
    func testWrongTypeDropsTheWholeBlock() throws {
        var payload = full
        payload["sessPowerAvg"] = "23.8"
        XCTAssertNil(try decode(payload).observed)
    }

    /// An out-of-range number must not reach the footer and render as "inf".
    ///
    /// Note where this is actually caught: `JSONDecoder` throws on the literal,
    /// so `ObservedStats.isPresentable`'s finiteness check never sees it. That
    /// check exists for the in-process provider (roadmap Phase 3), which will
    /// build the struct from arithmetic rather than from a document. This test
    /// pins the JSON boundary; it is not a test of that guard.
    func testOutOfRangeNumberIsRejected() throws {
        var payload = full
        payload["sessPowerPeak"] = Double.greatestFiniteMagnitude
        XCTAssertNotNil(try decode(payload).observed, "large but finite is a real reading")

        let overflowing = """
        {"schemaVersion":1,"state":"Connected",
         "obsSeconds":8040,"obsCoverage":0.94,"sessPingAvg":29,"sessCleanPct":92,
         "sessDegradedPct":6,"sessDarkPct":2,"sessOutages":11,"sessOutageSeconds":143,
         "sessLongestOutage":58,"sessDownPeak":1e400,"sessUpPeak":41,
         "sessDownBytes":4.2e9,"sessUpBytes":6e8,"sessPowerAvg":23.8,"sessPowerPeak":48.1,"sessEnergyWh":53.2}
        """
        let d = try JSONDecoder().decode(DishData.self, from: Data(overflowing.utf8))
        XCTAssertNil(d.observed, "an out-of-range number must not reach the footer")
    }

    /// The block is not required for the rest of the payload to decode — a
    /// missing footer must degrade the footer, nothing else.
    func testDroppingTheBlockLeavesTheRestIntact() throws {
        let d = try decode(["state": "Connected", "pingMs": 17.6, "signalScore": 71])
        XCTAssertNil(d.observed)
        XCTAssertEqual(d.state, .connected)
        XCTAssertEqual(d.pingMs, 17.6)
        XCTAssertEqual(d.signalScore, 71)
    }

    /// Regression for the bug this whole split exists to prevent: absent fields
    /// must decode to neutral values, never to the design mockup's numbers.
    func testMissingFieldsDoNotBecomeSampleData() throws {
        let d = try decode(["state": "Connected", "pingMs": 17.6, "upMbps": 0.4])
        XCTAssertEqual(d.downMbps, 0, "must not fall back to the mockup's 142.5")
        XCTAssertEqual(d.signalScore, 0, "must not fall back to the mockup's 86")
        XCTAssertEqual(d.uptimeHours, 0, "must not fall back to the mockup's 7.3")
        XCTAssertNotEqual(d.downMbps, DishData.sample.downMbps)
    }

    /// Sample data is constructed, never decoded.
    func testSampleCarriesAnObservedBlock() {
        XCTAssertNotNil(DishData.sample.observed)
        XCTAssertNil(DishData().observed, "the neutral default is no footer")
    }
}

/// Decodes a real payload captured from `dishwatch json` against a live dish,
/// with the device id redacted. This is the cheap half of the roadmap's Phase 5
/// contract work: it catches a Go JSON tag and a Swift `CodingKey` drifting
/// apart, which no amount of hand-written fixtures will.
final class GoldenFixtureTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testLiveConnectedFixture() throws {
        let d = try JSONDecoder().decode(DishData.self, from: fixture("live-connected"))
        XCTAssertEqual(d.state, .connected)
        XCTAssertGreaterThan(d.signalScore, 0)
        XCTAssertGreaterThan(d.powerW, 0)
        XCTAssertFalse(d.hardwareShort.isEmpty)
        XCTAssertTrue(d.deviceId.hasPrefix("ut"), "deviceId must be the dish id, not its model string")
        XCTAssertNotEqual(d.deviceId, d.hardwareShort)
        XCTAssertEqual(d.pingSeries.count, 60)
        XCTAssertEqual(d.powerSeries.count, 60)
        // Captured with `json --window 60`, and the CLI reports back what it
        // actually returned. Every sparkline caption reads this rather than the
        // window it requested, so it has to survive the wire.
        XCTAssertEqual(d.seriesSeconds, 60)

        // The fixture is a capture of the incident state, so assert the fields
        // that describe it. Without these a regression that started publishing
        // an average from the quarantined pair would keep this test green.
        XCTAssertFalse(d.energyCoversBoot, "the capture's samples do not cover its boot")
        XCTAssertEqual(d.energyAvgW, 0, "an inconsistent pair must yield no average")
        XCTAssertGreaterThan(d.energyWhSinceBoot, 0)
        XCTAssertGreaterThan(try XCTUnwrap(d.observed).energyWh, 0,
                             "the session block carries its own energy, from its own samples")

        // The whole session block survives a round trip through the real CLI.
        let o = try XCTUnwrap(d.observed, "the CLI emitted a complete sess* block; it must decode")
        XCTAssertGreaterThanOrEqual(o.seconds, ObservedStats.minSeconds)
        XCTAssertGreaterThan(o.pingAvg, 0)
        XCTAssertEqual(o.cleanPct + o.degradedPct + o.darkPct, 100, accuracy: 0.5)
    }
}

/// The two keys that are strict, and why.
///
/// Both were lenient. `state` fell back to `.offline` inside a `try?`, so a Go
/// side that renamed or added a case rendered correct, current metrics under a
/// wrong header with a footer still reading "live" — the failure was invisible
/// on both sides of the pipe. `schemaVersion` did not exist at all, so a field
/// rename needed no bump anywhere.
final class ContractStrictnessTests: XCTestCase {

    private func decode(_ json: String) throws -> DishData {
        try JSONDecoder().decode(DishData.self, from: Data(json.utf8))
    }

    func testMissingSchemaVersionIsRejected() {
        XCTAssertThrowsError(try decode(#"{"state":"Connected","pingMs":17.6}"#),
                             "a payload with no schemaVersion predates the contract")
    }

    func testWrongSchemaVersionIsRejected() {
        XCTAssertThrowsError(try decode(#"{"schemaVersion":99,"state":"Connected"}"#))
    }

    func testMissingStateIsRejected() {
        XCTAssertThrowsError(try decode(#"{"schemaVersion":1,"pingMs":17.6}"#),
                             "state is the discriminator; absent it the snapshot is unusable")
    }

    func testUnknownStateIsRejected() {
        // The concrete regression: a future CLI adds a "Booting" state. Under
        // the old decoder this became .offline and everything else rendered as
        // live.
        XCTAssertThrowsError(try decode(#"{"schemaVersion":1,"state":"Booting","pingMs":17.6}"#))
    }

    func testMistypedStateIsRejected() {
        XCTAssertThrowsError(try decode(#"{"schemaVersion":1,"state":42}"#))
    }

    func testMetricsStayLenient() throws {
        // Additive and partial payloads must still work: only the two keys
        // above are strict, or every new Go field becomes a breaking change.
        let d = try decode(#"{"schemaVersion":1,"state":"Connected","somethingNew":123}"#)
        XCTAssertEqual(d.state, .connected)
        XCTAssertEqual(d.pingMs, 0, "absent metric reads as no-reading, not as a mock-up default")
        XCTAssertEqual(d.downMbps, 0)
    }
}
