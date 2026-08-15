import XCTest
@testable import DishWatch

/// `AppState.quality` is the single place the UI asks "can I trust what I am
/// about to draw", so its mapping is worth pinning. The first version of this
/// enum shipped a regression the review caught: it collapsed every non-connected
/// dish state into "no dish at this address", which took a live, correct reading
/// of a weak link and captioned it as an absent dish.
@MainActor
final class QualityTests: XCTestCase {

    private func store(_ provider: DishProvider) -> AppState {
        AppState(provider: provider)
    }

    /// A provider that returns whatever it is given, once.
    private struct Fixed: DishProvider {
        let value: DishData
        func poll(window: Int) async throws -> DishData { value }
    }
    private struct Failing: DishProvider {
        struct Boom: Error {}
        func poll(window: Int) async throws -> DishData { throw Boom() }
    }

    func testWeakIsLive() async {
        var d = DishData.sample
        d.state = .weak
        let s = store(Fixed(value: d))
        await s.refresh()
        XCTAssertTrue(s.quality.isTrustworthy,
                      "a weak link is a real, current reading — swiftState maps every non-connected, non-disabled dish state to Weak, so this is the common case whenever the link is imperfect")
    }

    func testConnectedIsLive() async {
        var d = DishData.sample
        d.state = .connected
        let s = store(Fixed(value: d))
        await s.refresh()
        XCTAssertTrue(s.quality.isTrustworthy)
    }

    /// The dish answered and reported itself disabled. That is a fact, not a
    /// failure, so the numbers are not dimmed — but it is not "live" either.
    func testDisabledIsTrustworthyButNotOffline() async {
        var d = DishData.sample
        d.state = .disabled
        let s = store(Fixed(value: d))
        await s.refresh()
        XCTAssertTrue(s.quality.isTrustworthy)
        if case .disabled = s.quality {} else {
            XCTFail("expected .disabled, got \(s.quality)")
        }
    }

    func testOfflineIsNotTrustworthy() async {
        var d = DishData.sample
        d.state = .offline
        let s = store(Fixed(value: d))
        await s.refresh()
        XCTAssertFalse(s.quality.isTrustworthy)
        if case .offline = s.quality {} else {
            XCTFail("expected .offline, got \(s.quality)")
        }
    }

    func testFailedPollIsStaleNotOffline() async {
        let s = store(Failing())
        await s.refresh()
        XCTAssertFalse(s.quality.isTrustworthy)
        if case .stale = s.quality {} else {
            XCTFail("a transport failure is stale — the dish state is unknown, not known-absent; got \(s.quality)")
        }
    }

    /// A release build that cannot find its helper is a broken install, not a
    /// demo. This used to fall through to `.sample` and tell the user they were
    /// looking at sample data, which is both wrong and unactionable.
    func testMissingHelperIsBrokenInstallNotSample() async {
        let s = store(MissingHelperProvider())
        await s.refresh()
        if case .brokenInstall = s.quality {} else {
            XCTFail("expected .brokenInstall, got \(s.quality)")
        }
        XCTAssertFalse(s.quality.isTrustworthy)
    }

    func testSampleProviderIsSample() async {
        let s = store(SampleProvider())
        await s.refresh()
        if case .sample = s.quality {} else {
            XCTFail("expected .sample, got \(s.quality)")
        }
    }
}
