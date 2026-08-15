import XCTest
@testable import DishWatch

/// `Spark` stopped being a one-line decoration the moment download and upload
/// went onto one axis: it now has a shared range, a right-alignment rule for
/// ragged series, and a column index the scrub gesture addresses samples by.
/// All three are arithmetic that renders as a *plausible picture* when wrong,
/// which is the kind worth pinning in a test rather than in an eyeball.
final class SparkTests: XCTestCase {

    private func trace(_ values: [Double]) -> SparkTrace {
        SparkTrace(values: values, color: .clear)
    }

    // MARK: - columns

    /// A column is a one-second step, and the count comes from the *widest*
    /// trace — the shorter one is missing its oldest seconds, not compressing
    /// the same span into fewer of them.
    func testSpanIsTheWidestTraceMinusOne() {
        XCTAssertEqual(Spark.span([trace([1, 2, 3]), trace([1, 2])]), 2)
        XCTAssertEqual(Spark.span([trace([1])]), 0, "one sample spans nothing")
        XCTAssertEqual(Spark.span([]), 0)
    }

    /// Traces are right-aligned to now. A 4-sample series beside a 6-sample one
    /// starts two columns in; reading it from column 0 would relabel every one
    /// of its samples as two seconds older than it is.
    func testShortTracesAreRightAlignedNotStretched() {
        let long = trace([10, 20, 30, 40, 50, 60])
        let short = trace([1, 2, 3, 4])
        let span = Spark.span([long, short])
        XCTAssertEqual(span, 5)

        XCTAssertEqual(Spark.sample(long, at: span, span: span), 60, "the last column is now")
        XCTAssertEqual(Spark.sample(short, at: span, span: span), 4, "…for every trace")
        XCTAssertEqual(Spark.sample(short, at: 2, span: span), 1, "the short trace starts here")
        XCTAssertNil(Spark.sample(short, at: 1, span: span), "and has nothing before it")
        XCTAssertNil(Spark.sample(short, at: 0, span: span))
        XCTAssertEqual(Spark.sample(long, at: 0, span: span), 10)
    }

    /// The scrub gesture hands over a raw pointer position, including ones past
    /// either edge — a drag does not stop at the view's bounds.
    func testColumnRoundsToTheNearestSampleAndClamps() {
        XCTAssertEqual(Spark.column(atX: 0, width: 100, span: 10), 0)
        XCTAssertEqual(Spark.column(atX: 100, width: 100, span: 10), 10)
        XCTAssertEqual(Spark.column(atX: 54, width: 100, span: 10), 5)
        XCTAssertEqual(Spark.column(atX: 56, width: 100, span: 10), 6, "nearest, not floor")
        XCTAssertEqual(Spark.column(atX: -30, width: 100, span: 10), 0, "a drag runs off the edge")
        XCTAssertEqual(Spark.column(atX: 300, width: 100, span: 10), 10)
        XCTAssertEqual(Spark.column(atX: 50, width: 0, span: 10), 0, "no width, no columns")
        XCTAssertEqual(Spark.column(atX: 50, width: 100, span: 0), 0)
    }

    // MARK: - the throughput row's contract

    /// The reason the two directions can share a chart at all: same unit, same
    /// window. The values a scrub reads back are the dish's own samples, not
    /// anything re-derived from the drawing.
    func testScrubReadsBackTheSamplesThatWerePlotted() {
        let down = SparkTrace(symbol: "↓", values: [120, 150, 96, 188], color: .clear)
        let up = SparkTrace(symbol: "↑", values: [10, 12, 9, 14], color: .clear)
        let span = Spark.span([down, up])
        for c in 0...span {
            XCTAssertEqual(Spark.sample(down, at: c, span: span), down.values[c])
            XCTAssertEqual(Spark.sample(up, at: c, span: span), up.values[c])
        }
    }

    /// A ragged pair is the case the right-alignment rule exists for, and the
    /// one a `↓`-only or `↑`-only ring produces on real firmware.
    func testRaggedThroughputPairReadsBothTracesAtTheSameColumn() {
        let down = SparkTrace(symbol: "↓", values: [120, 150, 96, 188, 210], color: .clear)
        let up = SparkTrace(symbol: "↑", values: [9, 14], color: .clear)
        let span = Spark.span([down, up])

        XCTAssertEqual(Spark.sample(down, at: span, span: span), 210)
        XCTAssertEqual(Spark.sample(up, at: span, span: span), 14, "both traces end at now")
        XCTAssertEqual(Spark.sample(up, at: span - 1, span: span), 9)
        XCTAssertNil(Spark.sample(up, at: span - 2, span: span), "the upload ring stops here")
        XCTAssertEqual(Spark.sample(down, at: span - 2, span: span), 96, "…without silencing download")
    }

    /// Out-of-range columns are reachable without a bug: the marker survives a
    /// poll that hands back a shorter ring mid-drag.
    func testColumnsOutsideTheTraceReadNothing() {
        let t = trace([1, 2, 3])
        XCTAssertNil(Spark.sample(t, at: -1, span: 2))
        XCTAssertNil(Spark.sample(t, at: 3, span: 2))
        XCTAssertNil(Spark.sample(trace([]), at: 0, span: 0))
        XCTAssertNil(Spark.sample(trace([42]), at: 0, span: 5), "one sample, five columns back")
    }

    /// A non-finite value is not a sample. It cannot arrive through JSON, which
    /// has no way to spell one — but `ObservedStats.isPresentable` keeps the
    /// same guard for the same reason: the in-process provider that replaces the
    /// subprocess builds these numbers from divisions, not from a parsed
    /// document. Everything downstream of this — the marker dot, the readout,
    /// its `Int` conversion — assumes finiteness.
    func testNonFiniteSamplesAreNotSamples() {
        let t = trace([1, .nan, .infinity, -.infinity, 5])
        let span = Spark.span([t])
        XCTAssertEqual(Spark.sample(t, at: 0, span: span), 1)
        XCTAssertNil(Spark.sample(t, at: 1, span: span))
        XCTAssertNil(Spark.sample(t, at: 2, span: span))
        XCTAssertNil(Spark.sample(t, at: 3, span: span))
        XCTAssertEqual(Spark.sample(t, at: 4, span: span), 5)
    }

    /// The scrub readout's formatter is the one number on screen that comes
    /// straight from a ring sample rather than from a bounded statistic, so it
    /// must not be reachable by `Int(Double)`, which traps.
    func testThroughputFormatterSurvivesValuesIntWouldTrapOn() {
        XCTAssertEqual(MenuBarField.compactMbps(.nan), "—")
        XCTAssertEqual(MenuBarField.compactMbps(.infinity), "—")
        XCTAssertEqual(MenuBarField.compactMbps(1e300), String(format: "%.0f", 1e300),
                       "formatted, not converted")
        // And the ordinary contract is unchanged.
        XCTAssertEqual(MenuBarField.compactMbps(142.5), "143", "half away from zero, not to even")
        XCTAssertEqual(MenuBarField.compactMbps(9.96), "10")
        XCTAssertEqual(MenuBarField.compactMbps(0.4), "0.4")
    }
}
