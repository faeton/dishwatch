import Foundation
import os

/// Where the engine's diagnostics go, now that they go anywhere at all.
///
/// The app had a blind spot it already knew about. `helper.go` writes its
/// failures to stderr — a failed dial, a redial after a dropped connection, a
/// recovered panic — and `HelperProvider` set `standardError` to
/// `FileHandle.nullDevice`, so all of it went nowhere. The Go side even
/// complains about this in a comment: on a firmware change that renames a
/// field, the helper reports the real cause to stderr "which the app routes to
/// /dev/null", and the user sees a link that is up and an app that says
/// nothing useful.
///
/// **Deliberately `os_log`, not a crash-reporting service.** Sending
/// diagnostics off the machine would need a Diagnostics privacy label, a
/// privacy-policy URL, and — for any third-party SDK on Apple's list — a signed
/// XCFramework carrying its own privacy manifest. `docs/roadmap.md` already
/// dropped third-party geocoding to avoid exactly that, and `Info.plist` claims
/// nothing is sent anywhere else. The unified log costs none of it: the data
/// stays on the machine, the user can read it, and support can ask for it.
///
///     log show --last 1h --predicate 'subsystem == "com.dishwatch"'
///
/// Messages are logged `.public` on purpose. The default redacts interpolated
/// values to `<private>`, which would turn every one of these into a timestamp
/// with no content — the exact failure this exists to end. Nothing here carries
/// anything the user does not already see on screen: local addresses, our own
/// error strings, and the dish's own field names.
enum EngineLog {
    static let subsystem = "com.dishwatch"

    /// Verbatim stderr from the helper child process.
    private static let helperLog = Logger(subsystem: subsystem, category: "helper")
    /// Failures on the app's side of the pipe — decode, protocol, timeouts.
    private static let pollLog = Logger(subsystem: subsystem, category: "poll")
    /// Panel sizing. See `SettingsPanelProbe`.
    static let layout = Logger(subsystem: subsystem, category: "layout")

    /// One line the helper wrote to stderr. Already human-readable; passed
    /// through unchanged so the log says what the engine said.
    static func helper(_ line: String) {
        helperLog.error("\(line, privacy: .public)")
    }

    /// A failure the app itself hit. `context` names the operation so a log
    /// line is legible without the surrounding code — "poll failed" alone has
    /// been the shape of every unhelpful diagnostic in this app so far.
    static func failure(_ context: String, _ error: Error) {
        pollLog.error("\(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    static func failure(_ context: String, _ message: String) {
        pollLog.error("\(context, privacy: .public): \(message, privacy: .public)")
    }
}
