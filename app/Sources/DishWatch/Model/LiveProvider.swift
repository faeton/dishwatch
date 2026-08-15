import Foundation

/// Real data: runs `dishwatch json` and decodes the Dashboard into DishData.
/// This reuses the CLI's gRPC client, energy integrator, and power-bank state,
/// so the app reflects exactly what `sl`/`dishwatch` sees (incl. pb disabled).
///
/// (The App Store build will replace this with an in-process c-archive call —
/// see docs/roadmap.md — but shelling out gives real data today.)
final class LiveProvider: DishProvider, @unchecked Sendable {
    enum LiveError: LocalizedError {
        case binaryNotFound
        case nonZeroExit(Int32, String)
        var errorDescription: String? {
            switch self {
            case .binaryNotFound: return "dishwatch binary not found"
            case .nonZeroExit(let code, let msg): return "dishwatch json exited \(code): \(msg)"
            }
        }
    }

    /// Cached resolved path to the binary.
    private let binary: String?

    init() { self.binary = Self.locateBinary() }

    func poll(window: Int) async throws -> DishData {
        guard let binary else { throw LiveError.binaryNotFound }
        let (out, err, code) = try Self.run(binary, ["json", "--window", "\(window)"])
        guard code == 0 else {
            throw LiveError.nonZeroExit(code, String(data: err, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(DishData.self, from: out)
    }

    /// Reboot the dish via `dishwatch reboot`. Throws on missing binary / failure.
    func reboot() async throws {
        guard let binary else { throw LiveError.binaryNotFound }
        let (_, err, code) = try Self.run(binary, ["reboot"])
        guard code == 0 else {
            throw LiveError.nonZeroExit(code, String(data: err, encoding: .utf8) ?? "")
        }
    }

    // MARK: - binary discovery

    /// Finder-launched apps inherit a minimal PATH, so search explicit
    /// locations: env override, Homebrew (arm + intel), /usr/local, the repo
    /// dev build, then PATH.
    static func locateBinary() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["DISHWATCH_BIN"], !env.isEmpty {
            candidates.append(env)
        }
        #if DEBUG
        // Dev convenience only: prefer the repo build over a possibly-stale
        // Homebrew install that may predate the `json` command. Must not ship —
        // a release build that found a developer's checkout on a user's machine
        // would silently run an unknown binary.
        candidates.append(fm.homeDirectoryForCurrentUser.path + "/Sites/dishwatch/bin/dishwatch")
        #endif
        candidates += [
            "/opt/homebrew/bin/dishwatch",
            "/usr/local/bin/dishwatch",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) { return path }
        // Fall back to `which dishwatch` under a login shell (picks up user PATH).
        if let p = try? run("/bin/zsh", ["-lc", "command -v dishwatch"]).0,
           let s = String(data: p, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty, fm.isExecutableFile(atPath: s) {
            return s
        }
        return nil
    }

    /// Run a process to completion, returning (stdout, stderr, exitCode).
    static func run(_ launchPath: String, _ args: [String]) throws -> (Data, Data, Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        // Read before waitUntilExit to avoid deadlock on large output.
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (out, err, proc.terminationStatus)
    }
}
