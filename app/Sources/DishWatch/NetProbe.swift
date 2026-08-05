import Foundation
import Network
import ServiceManagement

/// The roadmap's Phase 2 spike, as code rather than a guess.
///
/// The open architecture decision is Option A (Go core linked in as a
/// `c-archive`) versus Option B (pure Swift over a vendored proto), and the
/// deciding risk in both is the same: whether a *sandboxed, signed* bundle can
/// open a TCP connection to 192.168.100.1 at all. Local Network permission has
/// a track record of working from Terminal and failing inside an app bundle, so
/// nothing about running the CLI by hand predicts this.
///
/// What makes the spike worth running rather than reasoning about is that the
/// two options reach the network through different stacks. Option B would use
/// `NWConnection`, which is what TCC is designed around and which triggers the
/// permission prompt properly. Option A drags in Go's runtime, whose net
/// package uses raw BSD sockets and knows nothing about `NEHelper` or the
/// prompt. If those two disagree, the disagreement *is* the decision. So probe
/// both, in the same process, under the same signature.
///
/// `DISHWATCH_NETPROBE=1` runs it and exits. Dev scaffolding — listed in
/// docs/roadmap.md under "cut before submission".
enum NetProbe {
    /// Where the dish lives, overridable so the probe can be pointed at a
    /// reachable control host to tell "sandbox blocked it" from "nothing is
    /// listening".
    static var target: (host: String, port: UInt16) {
        let raw = ProcessInfo.processInfo.environment["STARLINK_DISH"] ?? "192.168.100.1:9200"
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let p = UInt16(parts[1]) else { return ("192.168.100.1", 9200) }
        return (String(parts[0]), p)
    }

    /// `DISHWATCH_NETPROBE=1` writes to stderr; `DISHWATCH_NETPROBE=<path>`
    /// writes there instead.
    ///
    /// The path form is not a convenience. Running the bundle's Mach-O from a
    /// shell makes Terminal the *responsible process* for TCC, so the app can
    /// inherit a Local Network grant Terminal already has and report a success
    /// that says nothing about how it will behave for a user. The only way to
    /// measure the real thing is to launch through LaunchServices (`open`),
    /// where the app is responsible for itself — and then stderr goes nowhere,
    /// so the result has to land in a file. Under the sandbox that file must be
    /// inside the container, which is also a free check that the container is
    /// where we think it is.
    static func runIfRequested() -> Bool {
        guard let mode = ProcessInfo.processInfo.environment["DISHWATCH_NETPROBE"] else { return false }
        let (host, port) = target
        let info = Bundle.main.infoDictionary
        // .status is a read — it reports whether we *could* be a login item and
        // whether we currently are. Deliberately not .register(): a probe has no
        // business installing a login item as a side effect of being run.
        let loginItem: String
        if Bundle.main.bundleIdentifier == nil {
            loginItem = "unavailable — no bundle identifier"
        } else {
            switch SMAppService.mainApp.status {
            case .enabled:        loginItem = "enabled"
            case .notRegistered:  loginItem = "available, not registered"
            case .requiresApproval: loginItem = "available, awaiting user approval in System Settings"
            case .notFound:       loginItem = "notFound — the bundle is not where LaunchServices expects"
            @unknown default:     loginItem = "unknown status"
            }
        }
        let report = """
            NETPROBE target=\(host):\(port)
              bundle id     : \(Bundle.main.bundleIdentifier ?? "(none — not running from a bundle)")
              version       : \(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "-"))
              login item    : \(loginItem)
              sandboxed     : \(isSandboxed)
              home          : \(FileManager.default.homeDirectoryForCurrentUser.path)
              responsible   : \(launchedByLaunchServices ? "self (opened via LaunchServices)" : "inherited (run from a shell — TCC result is not trustworthy)")
              NWConnection  : \(probeNetworkFramework(host: host, port: port))
              BSD socket    : \(probePOSIX(host: host, port: port))
            """
        if mode == "1" || mode.isEmpty {
            emit(report)
        } else {
            try? report.write(toFile: mode, atomically: true, encoding: .utf8)
        }
        return true
    }

    /// LaunchServices does not hand the process a controlling terminal; a
    /// shell-run one always has stdin on a tty. Crude, but it distinguishes
    /// exactly the two cases that matter here.
    static var launchedByLaunchServices: Bool { isatty(STDIN_FILENO) == 0 }

    /// The sandbox rewrites HOME to the container, which is the cheapest
    /// reliable signal from inside the process — `app-sandbox` in the signature
    /// is not readable without extra entitlements.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
            || FileManager.default.homeDirectoryForCurrentUser.path.contains("/Library/Containers/")
    }

    // MARK: - the two stacks

    /// Path B: Network.framework, which participates in Local Network TCC and
    /// will surface a prompt (or a denial) the way the OS intends.
    private static func probeNetworkFramework(host: String, port: UInt16) -> String {
        let conn = NWConnection(
            host: .init(host),
            port: .init(rawValue: port)!,
            using: .tcp)
        let sem = DispatchSemaphore(value: 0)
        var result = "timeout after 8s (no state change — a pending permission prompt looks like this)"
        var settled = false
        conn.stateUpdateHandler = { state in
            guard !settled else { return }
            switch state {
            case .ready:
                result = "ready — connected"
                settled = true; sem.signal()
            case .failed(let e):
                result = "failed — \(e)"
                settled = true; sem.signal()
            case .waiting(let e):
                // Waiting is not fatal on its own, but a local-network denial
                // parks here indefinitely rather than failing, so record it.
                result = "waiting — \(e)"
            default:
                break
            }
        }
        conn.start(queue: .global())
        _ = sem.wait(timeout: .now() + 8)
        conn.cancel()
        return result
    }

    /// Path A: a plain `connect(2)`, which is what Go's net package does inside
    /// a `c-archive` and what the CLI subprocess does today. Deliberately
    /// bypasses Network.framework, because that is the whole question.
    private static func probePOSIX(host: String, port: UInt16) -> String {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &info)
        guard rc == 0, let ai = info else {
            return "getaddrinfo failed — \(String(cString: gai_strerror(rc)))"
        }
        defer { freeaddrinfo(info) }

        let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { return "socket() failed — \(errnoText())" }
        defer { close(fd) }

        // Non-blocking connect + select, so a silently-dropped SYN times out
        // here instead of hanging the probe for the kernel's full 75 s.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        if connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
            return "connected immediately"
        }
        guard errno == EINPROGRESS else { return "connect() failed — \(errnoText())" }

        var wfds = fd_set()
        fdZero(&wfds); fdSet(fd, &wfds)
        var tv = timeval(tv_sec: 8, tv_usec: 0)
        let sel = select(fd + 1, nil, &wfds, nil, &tv)
        if sel == 0 { return "timeout after 8s (SYN went unanswered)" }
        if sel < 0 { return "select() failed — \(errnoText())" }

        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
        return soErr == 0 ? "connected" : "connect failed — \(String(cString: strerror(soErr))) (\(soErr))"
    }

    // MARK: - helpers

    private static func errnoText() -> String { "\(String(cString: strerror(errno))) (\(errno))" }

    // fd_set is a fixed-size tuple in Swift, so the FD_ZERO/FD_SET macros have
    // no import. The dish probe only ever tracks one descriptor.
    private static func fdZero(_ set: inout fd_set) {
        withUnsafeMutableBytes(of: &set.fds_bits) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
    }
    private static func fdSet(_ fd: Int32, _ set: inout fd_set) {
        let intOffset = Int(fd) / 32
        let bitOffset = Int(fd) % 32
        withUnsafeMutableBytes(of: &set.fds_bits) { raw in
            let words = raw.bindMemory(to: Int32.self)
            words[intOffset] |= Int32(1 << bitOffset)
        }
    }

    private static func emit(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
}
