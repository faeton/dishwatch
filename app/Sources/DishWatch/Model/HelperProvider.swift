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
        case badResponse(String)
        case remote(String)

        var errorDescription: String? {
            switch self {
            case .notFound:              return "dishwatch helper not found in the app bundle"
            case .launchFailed(let m):   return "could not start the helper: \(m)"
            case .protocolMismatch(let v): return "helper speaks protocol \(v), this app expects \(HelperProvider.expectedProtocol)"
            case .died:                  return "the helper stopped responding"
            case .badResponse(let m):    return "unreadable helper response: \(m)"
            case .remote(let m):         return m
            }
        }
    }

    /// Bumped whenever a request or response shape changes incompatibly. The
    /// helper announces its own in a banner; a mismatch fails closed rather
    /// than hoping the fields line up, because a silently misread Dashboard is
    /// exactly the fabricated-data failure the Observed decode work exists to
    /// prevent.
    static let expectedProtocol = 1

    // MARK: - wire types

    private struct Banner: Decodable {
        let protocolVersion: Int
        let helper: String
        let version: String
        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol", helper, version
        }
    }

    private struct Response: Decodable {
        let id: Int64
        let ok: Bool
        let data: DishData?
        let error: String?
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

    /// Version string the running helper reported, for Settings/diagnostics.
    private(set) var helperVersion: String?

    deinit { queue.sync { shutdown() } }

    // MARK: - DishProvider

    func poll() async throws -> DishData {
        try await request(["op": "poll"])
    }

    func reboot() async throws {
        _ = try? await request(["op": "reboot"])
    }

    /// Maps to `sl pb <pct> [wh]`. `wh == nil` keeps whatever capacity the
    /// existing anchor carried.
    func setAnchor(pct: Double, wh: Double?) async throws {
        var body: [String: Any] = ["op": "setAnchor", "pct": pct]
        if let wh { body["wh"] = wh }
        _ = try? await request(body)
    }

    // MARK: - request plumbing

    @discardableResult
    private func request(_ body: [String: Any]) async throws -> DishData {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    cont.resume(returning: try self.requestLocked(body))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func requestLocked(_ body: [String: Any]) throws -> DishData {
        do {
            let d = try send(body)
            consecutiveFailures = 0
            return d
        } catch {
            // A dead pipe is the expected failure here, not an exceptional one:
            // the helper redials the dish itself, so if *it* has gone away the
            // process died. Tear down and try once on a fresh child, so a crash
            // costs one poll rather than requiring the user to restart the app.
            consecutiveFailures += 1
            shutdown()
            guard consecutiveFailures <= 3 else { throw error }
            return try send(body)
        }
    }

    private func send(_ body: [String: Any]) throws -> DishData {
        try ensureRunning()
        guard let toHelper, let fromHelper else { throw HelperError.died }

        let id = nextID
        nextID += 1
        var payload = body
        payload["id"] = id

        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(0x0A)
        do {
            try toHelper.write(contentsOf: line)
        } catch {
            throw HelperError.died
        }

        guard let raw = fromHelper.readLine() else { throw HelperError.died }
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
        guard let data = resp.data else { throw HelperError.badResponse("ok with no data") }
        return data
    }

    // MARK: - lifecycle

    private func ensureRunning() throws {
        if let p = process, p.isRunning { return }
        shutdown()

        guard let path = Self.locateHelper() else { throw HelperError.notFound }

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
            throw HelperError.launchFailed(error.localizedDescription)
        }

        let reader = BufferedLineReader(handle: outPipe.fileHandleForReading)
        guard let bannerLine = reader.readLine() else {
            p.terminate()
            throw HelperError.launchFailed("helper exited before announcing itself")
        }
        guard let banner = try? JSONDecoder().decode(Banner.self, from: bannerLine) else {
            p.terminate()
            throw HelperError.launchFailed("unreadable banner")
        }
        guard banner.protocolVersion == Self.expectedProtocol else {
            p.terminate()
            throw HelperError.protocolMismatch(banner.protocolVersion)
        }

        process = p
        toHelper = inPipe.fileHandleForWriting
        fromHelper = reader
        helperVersion = banner.version
    }

    private func shutdown() {
        // Closing stdin is the polite exit — the helper's read loop ends and it
        // shuts its connection down itself. terminate() is the backstop for one
        // that has stopped reading.
        try? toHelper?.close()
        if let p = process, p.isRunning {
            p.terminate()
            // Don't wait indefinitely on a wedged child; it is a bounded,
            // sandboxed process and the OS will reap it.
            let deadline = Date().addingTimeInterval(2)
            while p.isRunning && Date() < deadline {
                usleep(20_000)
            }
        }
        process = nil
        toHelper = nil
        fromHelper = nil
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

/// Reads newline-delimited frames from a pipe.
///
/// `FileHandle.availableData` returns whatever has arrived, which for a pipe is
/// routinely a partial line or several lines at once — so the protocol needs
/// its own framing rather than assuming one read is one message. Blocking is
/// intended: callers are already on a dedicated queue.
private final class BufferedLineReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) { self.handle = handle }

    func readLine() -> Data? {
        while true {
            if let i = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<i]
                buffer.removeSubrange(buffer.startIndex...i)
                if line.isEmpty { continue }
                return Data(line)
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }   // EOF: the helper is gone
            buffer.append(chunk)
        }
    }
}
