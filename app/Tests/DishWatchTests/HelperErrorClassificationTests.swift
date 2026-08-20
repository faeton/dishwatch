import XCTest
@testable import DishWatch

/// How a helper failure is classified decides whether a working child process
/// gets killed, so the matrix is worth pinning even though the supervisor
/// itself is not unit-testable without a real process.
///
/// The bug this guards: `.remote` — the helper answering `ok:false` — was
/// classified like a dead pipe, so every application error tore down a healthy
/// child and forked a new one. `helper.go` returns application errors for the
/// failures that *repeat* (firmware renames a field, the dish answers but
/// cannot be decoded), so the steady state was one respawn per poll.
final class HelperErrorClassificationTests: XCTestCase {

    /// A reply is never a reason to restart anything, whatever it says.
    func testRemoteIsTheHelperAnswering() {
        XCTAssertTrue(HelperProvider.HelperError.remote("dish said no").isApplicationError)
    }

    /// Everything else is the channel failing, not the helper answering.
    func testChannelFailuresAreNotApplicationErrors() {
        let channel: [HelperProvider.HelperError] = [
            .died, .timedOut("poll"), .badResponse("{"), .launchFailed("x"),
            .notFound, .protocolMismatch(2),
        ]
        for e in channel {
            XCTAssertFalse(e.isApplicationError, "\(e) must not be read as an answer")
        }
    }

    /// Respawning cannot fix a missing binary or a protocol this build cannot
    /// speak, so those must not loop.
    func testOnlyHopelessCasesAreNonTransient() {
        XCTAssertFalse(HelperProvider.HelperError.notFound.isTransient)
        XCTAssertFalse(HelperProvider.HelperError.protocolMismatch(2).isTransient)
        XCTAssertTrue(HelperProvider.HelperError.died.isTransient)
        XCTAssertTrue(HelperProvider.HelperError.timedOut("poll").isTransient)
    }

    /// The two axes are independent: `.remote` is transient by the old rule and
    /// must still never reach the restart path. This is the exact pair that
    /// produced the storm.
    func testRemoteIsTransientButStillMustNotRestart() {
        let e = HelperProvider.HelperError.remote("boom")
        XCTAssertTrue(e.isTransient)
        XCTAssertTrue(e.isApplicationError)
    }
}
