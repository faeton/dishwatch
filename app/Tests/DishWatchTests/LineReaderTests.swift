import XCTest
import Foundation
@testable import DishWatch

/// The framing and deadline layer under the helper protocol.
///
/// It had neither a timeout nor a way to distinguish "the helper exited" from
/// "the helper stopped answering": `readLine()` blocked on `availableData`
/// forever, and because the caller reaches it through a non-cancellable
/// continuation, one wedged helper parked the request queue for the life of the
/// app while the UI kept reporting "live".
final class BufferedLineReaderTests: XCTestCase {

    private func withPipe(_ body: (Pipe, BufferedLineReader) throws -> Void) rethrows {
        let p = Pipe()
        let r = BufferedLineReader(handle: p.fileHandleForReading)
        try body(p, r)
        try? p.fileHandleForWriting.close()
    }

    func testReadsOneLine() throws {
        try withPipe { p, r in
            p.fileHandleForWriting.write(Data(#"{"id":1}"#.utf8) + Data([0x0A]))
            let line = try XCTUnwrap(r.readLine(timeout: 1))
            XCTAssertEqual(String(decoding: line, as: UTF8.self), #"{"id":1}"#)
            XCTAssertFalse(r.hitEOF)
        }
    }

    /// A pipe read routinely returns several messages at once, so the framing
    /// cannot assume one read is one message.
    func testSplitsMultipleLinesFromOneWrite() throws {
        try withPipe { p, r in
            p.fileHandleForWriting.write(Data("a\nb\nc\n".utf8))
            XCTAssertEqual(String(decoding: try XCTUnwrap(r.readLine(timeout: 1)), as: UTF8.self), "a")
            XCTAssertEqual(String(decoding: try XCTUnwrap(r.readLine(timeout: 1)), as: UTF8.self), "b")
            XCTAssertEqual(String(decoding: try XCTUnwrap(r.readLine(timeout: 1)), as: UTF8.self), "c")
        }
    }

    /// …and equally often returns half of one.
    func testAssemblesAPartialLine() throws {
        try withPipe { p, r in
            p.fileHandleForWriting.write(Data("{\"id\":".utf8))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                p.fileHandleForWriting.write(Data("1}\n".utf8))
            }
            let line = try XCTUnwrap(r.readLine(timeout: 2))
            XCTAssertEqual(String(decoding: line, as: UTF8.self), #"{"id":1}"#)
        }
    }

    /// The headline fix: silence returns instead of blocking forever.
    func testTimesOutOnSilence() throws {
        try withPipe { _, r in
            let start = Date()
            XCTAssertNil(r.readLine(timeout: 0.2))
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 2, "must not block past its deadline")
            XCTAssertGreaterThanOrEqual(elapsed, 0.15, "must actually wait for the deadline")
            XCTAssertFalse(r.hitEOF,
                           "a timeout is not end-of-stream; the caller kills a wedged child either way but the two are different diagnoses")
        }
    }

    /// And the other outcome has to be distinguishable, because it is what
    /// decides whether a restart can help.
    func testEOFIsDistinctFromTimeout() throws {
        let p = Pipe()
        let r = BufferedLineReader(handle: p.fileHandleForReading)
        try p.fileHandleForWriting.close()
        XCTAssertNil(r.readLine(timeout: 1))
        XCTAssertTrue(r.hitEOF)
    }

    /// A reply that arrives during the wait is still returned, so a slow-but-
    /// alive helper is not killed merely for being slow.
    func testSlowReplyWithinDeadlineSucceeds() throws {
        try withPipe { p, r in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                p.fileHandleForWriting.write(Data("late\n".utf8))
            }
            XCTAssertEqual(String(decoding: try XCTUnwrap(r.readLine(timeout: 2)), as: UTF8.self), "late")
        }
    }

    /// Bytes buffered before EOF must be drained before EOF is reported, or the
    /// last reply of a helper that exits promptly afterwards is lost.
    func testDeliversBufferedLineBeforeReportingEOF() throws {
        let p = Pipe()
        let r = BufferedLineReader(handle: p.fileHandleForReading)
        p.fileHandleForWriting.write(Data("final\n".utf8))
        try p.fileHandleForWriting.close()
        XCTAssertEqual(String(decoding: try XCTUnwrap(r.readLine(timeout: 1)), as: UTF8.self), "final")
        XCTAssertNil(r.readLine(timeout: 1))
        XCTAssertTrue(r.hitEOF)
    }

    /// Blank lines are skipped rather than returned as empty frames, and the
    /// deadline still applies across them.
    func testSkipsBlankLines() throws {
        try withPipe { p, r in
            p.fileHandleForWriting.write(Data("\n\nreal\n".utf8))
            XCTAssertEqual(String(decoding: try XCTUnwrap(r.readLine(timeout: 1)), as: UTF8.self), "real")
        }
    }
}
