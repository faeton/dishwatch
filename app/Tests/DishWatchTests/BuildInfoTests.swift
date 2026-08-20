import XCTest
@testable import DishWatch

/// The build label exists because `CFBundleShortVersionString` could not do
/// this job, so the tests that matter are the ones checking it still cannot be
/// confused with it: a dev bundle and a release bundle cut from the same tag
/// must not produce the same string.
final class BuildInfoTests: XCTestCase {

    private func info(_ channel: BuildInfo.Channel,
                      short: String = "0.2.7",
                      build: String = "89",
                      source: String = "v0.2.7") -> BuildInfo {
        BuildInfo(shortVersion: short, buildNumber: build, channel: channel, sourceVersion: source)
    }

    /// The whole point, stated as one assertion.
    func testDevAndReleaseFromTheSameTagAreDistinguishable() {
        let release = info(.release)
        let dev = info(.dev, source: "v0.2.7-1-gcdd29ad-dirty")
        XCTAssertEqual(release.shortVersion, dev.shortVersion,
                       "precondition: the field that failed at this reports the same value for both")
        XCTAssertNotEqual(release.footerLabel, dev.footerLabel)
        XCTAssertNotEqual(release.detailLabel, dev.detailLabel)
    }

    func testReleaseFooterIsJustTheVersion() {
        XCTAssertEqual(info(.release).footerLabel, "v0.2.7")
    }

    func testDevFooterLeadsWithTheChannel() {
        XCTAssertEqual(info(.dev).footerLabel, "dev v0.2.7")
    }

    /// The star is the only mark of an uncommitted tree in the footer, and it
    /// is worth a test because `-dirty` is a suffix of the *source* version
    /// while the label is built from the *short* one — nothing else connects
    /// them.
    func testDirtyTreeGetsAStar() {
        XCTAssertEqual(info(.dev, source: "v0.2.7-1-gcdd29ad-dirty").footerLabel, "dev v0.2.7✱")
        XCTAssertEqual(info(.dev, source: "v0.2.7-1-gcdd29ad").footerLabel, "dev v0.2.7")
    }

    /// A release built from a dirty tree is a real thing — `make dmg` does not
    /// check — and it must say so rather than passing for a clean release.
    func testDirtyIsReadOffTheSourceVersionNotTheChannel() {
        XCTAssertTrue(info(.release, source: "v0.2.7-dirty").isDirty)
        XCTAssertFalse(info(.release).isDirty)
    }

    /// An unlabelled bundle claims nothing. `.unknown` is a bundle assembled by
    /// something other than `make app`, and calling it either channel would be
    /// a guess about provenance — the one subject this whole type exists to
    /// stop guessing about.
    func testUnknownChannelDrawsNothing() {
        XCTAssertNil(info(.unknown).footerLabel)
    }

    /// Degrades rather than traps, like the wire enums do.
    func testUnrecognisedChannelStringBecomesUnknown() {
        let bundle = FakeBundle(["DWBuildChannel": "nightly",
                                 "CFBundleShortVersionString": "0.2.7"])
        XCTAssertEqual(BuildInfo(bundle: bundle).channel, .unknown)
    }

    /// A bundle built by a Makefile older than these keys has neither. It must
    /// come out as `.unknown` with empty strings, not as a dev build.
    func testBundleWithoutTheKeysIsUnknownNotDev() {
        let b = BuildInfo(bundle: FakeBundle(["CFBundleShortVersionString": "0.2.6",
                                              "CFBundleVersion": "80"]))
        XCTAssertEqual(b.channel, .unknown)
        XCTAssertEqual(b.sourceVersion, "")
        XCTAssertFalse(b.isDirty)
        XCTAssertNil(b.footerLabel)
        XCTAssertEqual(b.detailLabel, "0.2.6 (80)")
    }

    /// Settings gets the whole thing, `-dirty` spelled out — a star does not
    /// paste into a bug report.
    func testDetailLabelSpellsOutTheSourceVersion() {
        XCTAssertEqual(info(.dev, source: "v0.2.7-1-gcdd29ad-dirty").detailLabel,
                       "0.2.7 (89) · dev · v0.2.7-1-gcdd29ad-dirty")
    }

    /// No redundant tail when the describe string adds nothing over the short
    /// version — a clean release on a tag should read `0.2.7 (89) · release`,
    /// not repeat itself.
    func testDetailLabelDoesNotRepeatTheVersion() {
        XCTAssertEqual(info(.release, source: "0.2.7").detailLabel, "0.2.7 (89) · release")
    }

    /// Never empty. Settings has a row to fill whatever the plist says.
    func testDetailLabelAlwaysSaysSomething() {
        let b = BuildInfo(bundle: FakeBundle([:]))
        XCTAssertFalse(b.detailLabel.isEmpty)
    }
}

/// Minimal `Bundle` stand-in — `infoDictionary` is the only thing BuildInfo
/// reads, and it is `open` on Bundle, so a subclass is enough. Constructing a
/// real bundle would mean writing a plist to disk for four assertions.
private final class FakeBundle: Bundle, @unchecked Sendable {
    private let dict: [String: Any]
    init(_ dict: [String: Any]) {
        self.dict = dict
        super.init()
    }
    override var infoDictionary: [String: Any]? { dict }
}
