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
/// Messages are logged `.public` on purpose: the default redacts interpolated
/// values to `<private>`, which would turn each of these into a timestamp with
/// no content — the exact failure this exists to end.
///
/// That is a real if small disclosure, and worth stating accurately rather than
/// waving away. An earlier version of this comment claimed nothing is logged
/// that the user cannot already see on screen; both reviewers pointed out that
/// this is false. Helper stderr is forwarded verbatim, so it can carry a
/// recovered panic value — the UI deliberately receives only "internal error
/// serving …" — a persistence path under the user's home directory, or the
/// first 200 bytes of a response that failed to decode.
///
/// None of it is credentials, and it stays on the machine. But `.public`
/// entries are readable in Console and are collected by a sysdiagnose, so treat
/// this as user-specific diagnostic data rather than as public information.
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
