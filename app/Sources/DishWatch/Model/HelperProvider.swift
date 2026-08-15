import Foundation

/// Live data from a supervised, long-lived `dishwatch helper` child.
///
/// This replaces `LiveProvider`'s spawn-per-poll bridge, which cannot work at
/// all in a sandboxed bundle — the sandbox denies access to a CLI installed
/// outside the app, so the Store build has no external binary to find. An
/// *embedded* helper is supported by Apple and measured working end to end
/// (see docs/roadmap.md).
///
/// It is also simply faster, though that turned out not to be the interesting
/// part: warm polls measure ~274 ms against 696 ms for spawn-per-poll, and
/// essentially all of the remainder is dish RPC time. The pipe round trip
/// itself is 0.014 ms, so the transport is free and the win is holding one
/// gRPC connection open rather than dialing and re-downloading reflection
/// descriptors every second.
///
/// **Supervision, not daemonisation.** The child is started on demand, killed
/// when this object goes away, and restarted with bounded backoff if it dies.
/// It is never installed, detached, or registered with launchd. The helper
/// exits by itself when its stdin closes, which is what stops a crashed app
/// from leaving one behind.
final class HelperProvider: DishProvider, @unchecked Sendable {

    enum HelperError: LocalizedError {
        case notFound
        case launchFailed(String)
        case protocolMismatch(Int)
        case died
        case timedOut(String)
        case badResponse(String)
        case remote(String)

        var errorDescription: String? {
            switch self {
            case .notFound:              return "dishwatch helper not found in the app bundle"
            case .launchFailed(let m):   return "could not start the helper: \(m)"
            case .protocolMismatch(let v): return "helper speaks protocol \(v), this app expects \(HelperProvider.expectedProtocol)"
            case .died:                  return "the helper stopped responding"
            case .timedOut(let op):      return "the helper did not answer \(op) in time"
            case .badResponse(let m):    return "unreadable helper response: \(m)"
            case .remote(let m):         return m
            }
        }

        /// Whether restarting the child could plausibly help. A helper that is
        /// missing, or that speaks a protocol this build does not know, will
        /// fail identically forever — respawning it is just process churn.
        var isTransient: Bool {
            switch self {
            case .notFound, .protocolMismatch: return false
            default:                           return true
            }
        }
    }

    /// Per-operation read deadlines.
    ///
    /// There were none. `readLine()` blocked on `availableData` forever, and
    /// `withCheckedThrowingContinuation` cannot be cancelled, so a helper that
    /// stopped answering parked the serial queue permanently: every later poll
    /// queued behind it and leaked a suspended Task, while the UI went on
    /// rendering the last snapshot with a footer reading "live". The Go side is
    /// bounded now too, but the client cannot rely on the peer to enforce the
    /// peer's own liveness.
    private enum Deadline {
        static let banner: TimeInterval = 2
        static let ping: TimeInterval = 1
        static let poll: TimeInterval = 15
        static let command: TimeInterval = 10

        static func forOp(_ op: String) -> TimeInterval {
            switch op {
            case "poll":   return poll
            case "ping":   return ping
            default:       return command
            }
        }
    }

    /// Bumped whenever a request or response shape changes incompatibly. The
    /// helper announces its own in a banner; a mismatch fails closed rather
    /// than hoping the fields line up, because a silently misread Dashboard is
    /// exactly the fabricated-data failure the Observed decode work exists to
    /// prevent.
    static let expectedProtocol = 3

    // MARK: - wire types

    private struct Banner: Decodable {
        let protocolVersion: Int
        let helper: String
        let version: String
        let restricted: Bool?
        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol", helper, version, restricted
        }
    }

    private struct Response: Decodable {
        let id: Int64
        let ok: Bool
        let data: DishData?
        let error: String?
        let warning: String?
        let elapsedMs: Int64?
    }

    // MARK: - state

    /// Everything below is touched only on this queue. The helper speaks a
    /// strictly alternating request/response protocol on one pipe, so
    /// serialising here is not a lock around shared state so much as the
    /// protocol's own requirement.
    private let queue = DispatchQueue(label: "dishwatch.helper")
    private var process: Process?
    private var toHelper: FileHandle?
    private var fromHelper: BufferedLineReader?
    private var nextID: Int64 = 1
    private var consecutiveFailures = 0
    private var nextLaunchNoEarlierThan: Date?

    /// Diagnostics, read under `lock` from any thread.
    private let diagLock = NSLock()
    private var _helperVersion: String?
    private var _helperRestricted: Bool?
    private var _lastWarning: String?
    private var _lastFailure: Error?

    /// Version string the running helper reported, for Settings/diagnostics.
    var helperVersion: String? { diagLock.withLock { _helperVersion } }
    /// Whether the running helper is the restricted `apphelper` build. A `false`
    /// here in a shipped app means the packaging step embedded the full CLI.
    var helperRestricted: Bool? { diagLock.withLock { _helperRestricted } }
    /// Non-fatal problem reported alongside the last good poll, e.g. state
    /// could not be persisted.
    private(set) var lastWarning: String? {
        get { diagLock.withLock { _lastWarning } }
        set { diagLock.withLock { _lastWarning = newValue } }
    }
    private(set) var lastFailure: Error? {
        get { diagLock.withLock { _lastFailure } }
        set { diagLock.withLock { _lastFailure = newValue } }
    }

    deinit {
        // Deliberately not `queue.sync`. The request closure captures self
        // strongly and is released *on* the queue, so if that release is the
        // last reference, deinit runs on the queue and queue.sync deadlocks on
        // itself. Tearing down directly is safe here precisely because deinit
        // means nothing else can still hold a reference to enqueue work.
        teardown()
    }

    // MARK: - DishProvider

    func poll(window: Int) async throws -> DishData {
        let resp = try await request(["op": "poll", "window": window], retry: true)
        guard let data = resp.data else { throw HelperError.badResponse("poll returned no data") }
        lastWarning = resp.warning
        return data
    }

    /// Reboot the dish. Throws so the caller can say it failed.
    ///
    /// `retry: false` is load-bearing. A reboot is not idempotent, and the
    /// natural failure — the dish acknowledging and then dropping the
    /// connection on its way down — looks exactly like a transport error, so a
    /// retry sends a second reboot to a dish already rebooting.
    func reboot() async throws {
        _ = try await request(["op": "reboot"], retry: false)
    }

    /// Maps to `sl pb <pct> [wh]`. `wh == nil` keeps whatever capacity the
    /// existing anchor carried.
    func setAnchor(pct: Double, wh: Double?) async throws {
        var body: [String: Any] = ["op": "setAnchor", "pct": pct]
        if let wh { body["wh"] = wh }
        _ = try await request(body, retry: false)
    }

    /// Liveness check that does not touch the dish.
    func ping() async throws {
        _ = try await request(["op": "ping"], retry: true)
    }

    // MARK: - request plumbing

    @discardableResult
    private func request(_ body: [String: Any], retry: Bool) async throws -> Response {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    cont.resume(returning: try self.requestLocked(body, retry: retry))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func requestLocked(_ body: [String: Any], retry: Bool) throws -> Response {
        do {
            let r = try send(body)
            noteSuccess()
            return r
        } catch let error as HelperError where !error.isTransient {
            // Missing binary or protocol mismatch: respawning cannot fix it, so
            // do not retry within this request. It still has to count as a
            // failure and extend the backoff — otherwise `consecutiveFailures`
            // stays at zero, `scheduleBackoff` keeps computing the shortest
            // delay, and a permanently broken install is retried five times a
            // second forever. Escalating means it settles at one attempt per
            // ten seconds, which is the right cadence for something only a
            // reinstall will fix.
            consecutiveFailures += 1
            lastFailure = error
            scheduleBackoff()
            throw error
        } catch {
            // A dead pipe is the expected failure here, not an exceptional one:
            // the helper redials the dish itself, so if *it* has gone away the
            // process died. Tear down and try once on a fresh child, so a crash
            // costs one poll rather than requiring the user to restart the app.
            consecutiveFailures += 1
            lastFailure = error
            shutdown()
            guard retry, consecutiveFailures <= 3 else { throw error }
            let r = try send(body)
            noteSuccess()
            return r
        }
    }

    /// Only a completed exchange clears the failure state. This used to reset
    /// solely on a first-try success, so a single recovered retry left the
    /// counter armed indefinitely.
    private func noteSuccess() {
        consecutiveFailures = 0
        nextLaunchNoEarlierThan = nil
        lastFailure = nil
    }

    private func send(_ body: [String: Any]) throws -> Response {
        try ensureRunning()
        guard let toHelper, let fromHelper else { throw HelperError.died }

        let id = nextID
        nextID += 1
        var payload = body
        payload["id"] = id
        let op = body["op"] as? String ?? "?"

        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(0x0A)
        do {
            try toHelper.write(contentsOf: line)
        } catch {
            throw HelperError.died
        }

        guard let raw = fromHelper.readLine(timeout: Deadline.forOp(op)) else {
            // Either EOF or the deadline. Both mean this child is no longer
            // useful; the caller's catch tears it down.
            throw fromHelper.hitEOF ? HelperError.died : HelperError.timedOut(op)
        }
        let resp: Response
        do {
            resp = try JSONDecoder().decode(Response.self, from: raw)
        } catch {
            throw HelperError.badResponse(String(decoding: raw.prefix(200), as: UTF8.self))
        }
        guard resp.id == id else {
            // The stream has desynchronised; a stale reply would be attributed
            // to the wrong request. Nothing sane to do but restart.
            throw HelperError.died
        }
        guard resp.ok else { throw HelperError.remote(resp.error ?? "helper reported failure") }
        // Deliberately no `data` requirement here. Commands acknowledge with
        // ok=true and no payload; demanding data on every reply made a
        // successful reboot raise "ok with no data", which the retry path read
        // as a dead pipe — so one click killed a healthy helper and sent the
        // reboot twice. Only `poll()` asks for data, and only poll returns it.
        return resp
    }

    // MARK: - lifecycle

    private func ensureRunning() throws {
        if let p = process, p.isRunning { return }
        shutdown()

        // Bounded exponential backoff. There was none, despite the class
        // documentation promising it: past the retry threshold `send` still
        // called this on every poll, so a helper that crashed on startup was
        // forked once per second, forever, with nothing escalating.
        if let earliest = nextLaunchNoEarlierThan, Date() < earliest {
            throw lastFailure ?? HelperError.died
        }

        guard let path = Self.locateHelper() else {
            scheduleBackoff()
            throw HelperError.notFound
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["helper"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        // Deliberately not a pipe: the helper writes diagnostics to stderr, and
        // nobody drains them here. A full pipe buffer would wedge the child.
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
        } catch {
            scheduleBackoff()
            throw HelperError.launchFailed(error.localizedDescription)
        }

        let reader = BufferedLineReader(handle: outPipe.fileHandleForReading)
        // The banner is bounded too. The helper only announces itself after its
        // eager dial, and reflection discovery on a connected-but-unresponsive
        // dish used to have no deadline — so this read could block forever and
        // the app would sit on "Connecting…" with no way out.
        guard let bannerLine = reader.readLine(timeout: Deadline.banner) else {
            hardKill(p)
            scheduleBackoff()
            throw HelperError.launchFailed("helper did not announce itself")
        }
        guard let banner = try? JSONDecoder().decode(Banner.self, from: bannerLine) else {
            hardKill(p)
            scheduleBackoff()
            throw HelperError.launchFailed("unreadable banner")
        }
        guard banner.protocolVersion == Self.expectedProtocol else {
            hardKill(p)
            throw HelperError.protocolMismatch(banner.protocolVersion)
        }

        process = p
        toHelper = inPipe.fileHandleForWriting
        fromHelper = reader
        diagLock.withLock {
            _helperVersion = banner.version
            _helperRestricted = banner.restricted
        }
    }

    /// `min(10s, 0.2s * 2^n)`, so a persistently broken helper settles into one
    /// launch every ten seconds instead of one per poll.
    private func scheduleBackoff() {
        let n = min(consecutiveFailures, 6)
        let delay = min(10.0, 0.2 * pow(2.0, Double(n)))
        nextLaunchNoEarlierThan = Date().addingTimeInterval(delay)
    }

    private func shutdown() {
        // Deliberately does NOT schedule backoff.
        //
        // It used to, and that quietly disabled the one-free-retry this class
        // documents: the catch in requestLocked calls shutdown() and then
        // immediately calls send() again, which goes through ensureRunning —
        // which refuses to launch before the deadline shutdown() had just set.
        // The retry could never start a child, so a helper that died mid-request
        // always cost a poll instead of costing nothing.
        //
        // Backoff belongs where a *launch* fails (ensureRunning) or where the
        // error cannot be fixed by relaunching (the non-transient catch). A
        // child dying mid-request is exactly the case worth retrying at once.
        teardown()
    }

    /// Close the pipes and make sure the child is actually gone.
    ///
    /// The old version closed stdin, sent SIGTERM, waited two seconds and then
    /// simply forgot the process — which was three separate mistakes. The
    /// helper registered SIGTERM with `signal.NotifyContext`, so the signal no
    /// longer terminated it (fixed on the Go side too); the parent still held
    /// the read end of the stdin pipe, so closing the write end may not even
    /// produce EOF; and dropping the reference left a live process holding the
    /// state lock while the next poll started a second one. SIGKILL cannot be
    /// caught or ignored, so it ends the sequence rather than hoping.
    private func teardown() {
        try? toHelper?.close()
        fromHelper?.close()
        if let p = process {
            hardKill(p)
        }
        process = nil
        toHelper = nil
        fromHelper = nil
    }

    private func hardKill(_ p: Process) {
        guard p.isRunning else { return }
        p.terminate()                                   // SIGTERM, now honoured
        let deadline = Date().addingTimeInterval(0.2)   // short: it exits on EOF
        while p.isRunning && Date() < deadline {
            usleep(10_000)
        }
        if p.isRunning {
            Foundation.kill(p.processIdentifier, SIGKILL)
        }
        // Reap, so the child does not linger as a zombie for the app's lifetime.
        // Safe now that the process is guaranteed dead or killed.
        p.waitUntilExit()
    }

    // MARK: - discovery

    /// The shipped helper lives beside the app's own executable inside the
    /// bundle. That is the only location a sandboxed build can use, and the
    /// only one a release build should trust.
    static func locateHelper() -> String? {
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let embedded = dir.appendingPathComponent("dishwatch-helper").path
            if FileManager.default.isExecutableFile(atPath: embedded) { return embedded }
        }
        #if DEBUG
        // Unbundled `swift run` during development has no Contents/MacOS to
        // look in. Never compiled into a release build — a shipped app that
        // went looking through $PATH could run an unknown binary.
        if let env = ProcessInfo.processInfo.environment["DISHWATCH_BIN"], !env.isEmpty,
           FileManager.default.isExecutableFile(atPath: env) { return env }
        let dev = FileManager.default.homeDirectoryForCurrentUser.path + "/Sites/dishwatch/bin/dishwatch"
        if FileManager.default.isExecutableFile(atPath: dev) { return dev }
        #endif
        return nil
    }
}

/// Reads newline-delimited frames from a pipe, with a deadline.
///
/// `FileHandle.availableData` returns whatever has arrived, which for a pipe is
/// routinely a partial line or several lines at once — so the protocol needs
/// its own framing rather than assuming one read is one message.
///
/// The deadline is the important part. `availableData` blocks indefinitely, and
/// the caller reaches it through a non-cancellable continuation, so a helper
/// that stopped answering used to park the request queue permanently: no
/// timeout, no cancellation, no recovery short of quitting the app — while the
/// UI kept showing the last snapshot labelled "live". Waiting is done with
/// `poll(2)` on the descriptor rather than a read on a background queue,
/// because abandoning an in-flight `availableData` would leave a second reader
/// racing the first for the same bytes.
/// Internal rather than private so the tests can drive it directly — the
/// deadline logic is new, subtle, and the thing a wedged helper depends on.
final class BufferedLineReader {
    private let handle: FileHandle
    private var buffer = Data()

    /// True when the last unsuccessful read was end-of-stream rather than a
    /// timeout, which is how the caller tells "helper exited" from "helper is
    /// wedged" — a distinction that decides whether restarting can help.
    private(set) var hitEOF = false

    init(handle: FileHandle) { self.handle = handle }

    func close() { try? handle.close() }

    func readLine(timeout: TimeInterval) -> Data? {
        hitEOF = false
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let i = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<i]
                buffer.removeSubrange(buffer.startIndex...i)
                if line.isEmpty { continue }
                return Data(line)
            }
            if deadline.timeIntervalSinceNow <= 0 { return nil }  // caller kills the child
            switch waitReadable(deadline) {
            case .timedOut:  return nil
            case .failed:    hitEOF = true; return nil
            case .readable:  break
            }
            let chunk = handle.availableData
            if chunk.isEmpty { hitEOF = true; return nil }   // EOF: the helper is gone
            buffer.append(chunk)
        }
    }

    private enum Wait { case readable, timedOut, failed }

    private func waitReadable(_ deadline: Date) -> Wait {
        // Loop on EINTR rather than reporting readable.
        //
        // Returning .readable on a signal-interrupted poll sent the caller
        // straight into `availableData` with nothing necessarily buffered — a
        // blocking read, which is the exact failure the deadline exists to
        // prevent, reachable any time a signal lands during the wait.
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .timedOut }
            var fds = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ms = Int32(min(Double(Int32.max), max(1, (remaining * 1000).rounded())))
            let n = withUnsafeMutablePointer(to: &fds) { poll($0, 1, ms) }
            if n < 0 {
                if errno == EINTR { continue }   // re-arm against the same deadline
                return .failed
            }
            if n == 0 { return .timedOut }
            // POLLHUP still delivers buffered bytes, so treat it as readable and
            // let the following read see the real EOF.
            return .readable
        }
    }
}
