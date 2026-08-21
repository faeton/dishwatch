import Foundation

/// Where *this Mac's* traffic leaves the network, as answered by a public
/// address reflector.
///
/// This is a different question from the one `DishData.countryCode` answers,
/// and the panel keeps them apart on purpose. The dish's country is the
/// terminal's own reading of what it believes it is licensed under; this is the
/// public address the Mac actually reaches the internet from, which is the only
/// one of the two that can say **whether this Mac is routing through the dish
/// at all**. A healthy dish and a laptop on a phone hotspot is an ordinary
/// Tuesday, and until now nothing in the app could tell you that had happened.
///
/// Three things are worth reading off it, in descending order of usefulness:
///
/// - `asn` — 14593 is Starlink. Anything else means the packets are not going
///   through the dish the rest of the panel is describing.
/// - `pop` — the Starlink ground station, parsed out of the reverse DNS name
///   (`customer.lndngbr1.isp.starlink.com` → `lndngbr1`). It explains latency
///   changes the dish itself never reports.
/// - `countryCode` — where the traffic exits, which is not where you are.
///
/// **Never fetched except on a press.** See `AppState.checkEgress` for the
/// consent rule; the short version is that the app talks only to
/// 192.168.100.1 until a user clicks the Check button — there is no timer, no
/// panel-open trigger and no setting that adds one — and Info.plist's Local
/// Network string says so.
struct Egress: Equatable {
    /// The public address the reflector saw. Shown, because it is the fact —
    /// the country and the operator are both derived from it.
    var ip: String = ""
    /// `"v4"` / `"v6"`, as reported. Which family answered is not cosmetic:
    /// Starlink hands out both, and their GeoIP records can disagree.
    var family: String = ""
    /// ISO 3166-1 alpha-2 of the *exit*, from the reflector's GeoIP database.
    var countryCode: String = ""
    /// Autonomous system number, or 0 when the reflector did not say.
    var asn: Int = 0
    /// The AS's registered name — long, shouty and comma-laden, e.g.
    /// `SPACEX-STARLINK - Space Exploration Technologies Corporation, US`.
    /// `operatorName` is what the panel draws.
    var asOrg: String = ""
    /// Reverse DNS of the exit address, when there is one. Absent on the v6
    /// side today, which is why `pop` is optional rather than a default.
    var reverse: String?
    /// Whether the reflector believes the address belongs to a VPN or proxy.
    /// A heuristic, and captioned as one.
    var viaVPN: Bool = false

    /// Starlink's ASN. The one magic number here, and the reason the whole
    /// feature is worth more than a flag.
    static let starlinkASN = 14593

    var isStarlink: Bool { asn == Self.starlinkASN }

    /// Flag and code — `🇬🇧 GB` — or `nil` when there is nothing honest to draw.
    ///
    /// Deliberately built from `DishData`'s primitives rather than reimplemented:
    /// a GeoIP database can answer a code Unicode has no flag for exactly as
    /// firmware can, and the two rows sit four lines apart in the same panel.
    /// One drawing `ZZ` while the other drew nothing for the same value would
    /// read as a bug in whichever row the user noticed second.
    var badge: String? {
        let code = countryCode.uppercased()
        guard DishData.isCodeShaped(code) else { return nil }
        guard let glyph = DishData.glyph(for: code) else { return code }
        return "\(glyph) \(code)"
    }

    /// A short name for whoever owns the address.
    ///
    /// `asOrg` is a registry field, not a label: `SPACEX-STARLINK - Space
    /// Exploration Technologies Corporation, US` is 62 characters and would
    /// wrap the row it sits in twice. Starlink is spelled out because that is
    /// the answer the user is looking for; everything else keeps its registry
    /// handle, which is short, stable, and not something we invented.
    var operatorName: String {
        if isStarlink { return "Starlink" }
        // The registry format is `HANDLE - Long Legal Name, CC`. Take the
        // handle when there is one, and otherwise the text before the comma —
        // never the whole string, which is where the wrapping comes from.
        let head = asOrg.components(separatedBy: " - ").first ?? asOrg
        let name = head.components(separatedBy: ", ").first ?? head
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return asn > 0 ? "AS\(asn)" : "unknown network" }
        guard trimmed.count > 28 else { return trimmed }
        // Trimmed *after* the cut as well as before it: the registry names that
        // need cutting are several words long, so the 27th character is as
        // likely as not a space, and "British Telecommunications …" reads as a
        // typo rather than as an elision.
        return trimmed.prefix(27).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The Starlink ground station, from reverse DNS, or `nil`.
    ///
    /// Only for names of the documented shape — `customer.<pop>.isp.starlink.com`
    /// — because the label is only meaningful inside it. Any other reverse name
    /// is somebody else's naming scheme and guessing at it would put a made-up
    /// place on the panel, which is the failure `countryBadge` exists to avoid.
    var pop: String? {
        guard let host = reverse?.lowercased(), host.hasSuffix(".isp.starlink.com") else { return nil }
        let labels = host.components(separatedBy: ".")
        // customer . lndngbr1 . isp . starlink . com  → the label before `isp`.
        guard labels.count >= 5, let isp = labels.firstIndex(of: "isp"), isp >= 1 else { return nil }
        let pop = labels[isp - 1]
        return pop.isEmpty || pop == "customer" ? nil : pop
    }

    /// The one-line reading: `🇬🇧 GB · Starlink · lndngbr1`.
    ///
    /// Degrades a piece at a time rather than all at once. A reflector that
    /// answers an address and nothing else still produces a useful line.
    var summary: String {
        var parts: [String] = []
        if let badge { parts.append(badge) }
        parts.append(operatorName)
        if let pop { parts.append(pop) }
        return parts.joined(separator: " · ")
    }

    /// The provenance line under the summary: the address itself and the AS.
    var detail: String {
        var parts = [ip]
        if asn > 0 { parts.append("AS\(asn)") }
        if !family.isEmpty { parts.append(family == "v6" ? "IPv6" : "IPv4") }
        return parts.joined(separator: " · ")
    }

    /// The sentence that is worth interrupting for, or `nil` when the reading
    /// is unremarkable.
    ///
    /// Two cases, and the first is the entire point of the feature: if the
    /// packets are not leaving through Starlink, every number above this row is
    /// describing a link this Mac is not using.
    var caution: String? {
        if !isStarlink && asn > 0 {
            return "This Mac is not routing through the dish — its traffic leaves via \(operatorName). The readings above still describe the dish."
        }
        if viaVPN {
            return "The exit looks like a VPN or proxy, so the country above is the VPN's, not yours."
        }
        return nil
    }
}

// MARK: - Decoding

extension Egress: Decodable {
    /// Every field is optional with a neutral default, for the same reason
    /// `DishData`'s decode is lenient: this is a third-party JSON document that
    /// can gain, lose or rename a key without warning, and a missing `reverse`
    /// must degrade one line of the panel rather than fail the whole lookup and
    /// report "could not check" over a perfectly good answer.
    enum CodingKeys: String, CodingKey {
        case ip, version, country, asn, asorg, reverse, vpn
    }

    /// `"vpn": {"vpn": false}` — an object, not a bool, and it may be absent.
    private struct VPNBlock: Decodable { let vpn: Bool? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var e = Egress()
        e.ip = (try? c.decode(String.self, forKey: .ip)) ?? ""
        e.family = (try? c.decode(String.self, forKey: .version)) ?? ""
        e.countryCode = (try? c.decode(String.self, forKey: .country)) ?? ""
        e.asn = (try? c.decode(Int.self, forKey: .asn)) ?? 0
        e.asOrg = (try? c.decode(String.self, forKey: .asorg)) ?? ""
        e.reverse = try? c.decode(String.self, forKey: .reverse)
        e.viaVPN = (try? c.decode(VPNBlock.self, forKey: .vpn))?.vpn ?? false

        // The one field that has to be there. An empty document, an HTML error
        // page that happened to parse, or a captive portal's JSON would
        // otherwise decode into a blank reading and be drawn as a fact.
        guard !e.ip.isEmpty else {
            throw EgressError.noAddress
        }
        self = e
    }
}

enum EgressError: LocalizedError, Equatable {
    case noAddress
    case http(Int)
    case notJSON

    var errorDescription: String? {
        switch self {
        case .noAddress:    return "the reply carried no address"
        case .http(let c):  return "the server answered \(c)"
        case .notJSON:      return "the reply was not the expected JSON"
        }
    }
}

// MARK: - The lookup

/// The one place in the app that opens a connection to something other than
/// the dish.
///
/// Kept as a free-standing enum rather than folded into `AppState` so the
/// decode half is testable without a network, and so the *whole* of the app's
/// third-party surface is one file you can read in a minute — which is what a
/// privacy claim in Info.plist has to be checkable against.
enum EgressLookup {
    static let defaultEndpoint = "https://ip.unt1.com/json"

    /// The host as shown to the user, so the disclosure text and the request
    /// can never drift apart.
    static func displayHost(_ url: URL) -> String { url.host ?? url.absoluteString }

    /// Where to ask. Overridable through a `UserDefaults` key with no UI: the
    /// service is one person's server, and an app that hard-codes a single
    /// third-party host with no way around it is one outage from a dead
    /// feature. There is deliberately no settings control — this is an escape
    /// hatch, not a choice a user should have to make.
    ///
    ///     defaults write com.faeton.dishwatch egressEndpoint https://example/json
    static func endpoint(_ defaults: UserDefaults) -> URL {
        if let s = defaults.string(forKey: "egressEndpoint"),
           let u = URL(string: s), u.scheme == "https" {
            return u
        }
        return URL(string: defaultEndpoint)!
    }

    /// A session that keeps nothing. No cookie store, no URL cache, no
    /// credential reuse: one request, one answer, no state that could make the
    /// next lookup identifiable as the same Mac.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.timeoutIntervalForResource = 8
        // Off, and this is the setting that decides what happens with no
        // route: `true` parks the request until connectivity returns, which
        // for a user-initiated check means a button that spins forever instead
        // of saying "offline".
        c.waitsForConnectivity = false
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: c)
    }()

    /// Identify the client honestly. A reflector operator who sees an
    /// unexplained burst of requests should be able to find out what is making
    /// them — the same courtesy `internal/geo` pays Nominatim, and for the same
    /// reason.
    static var userAgent: String {
        // `shortVersion` is empty outside a bundle — the SwiftPM binary and the
        // test harness both have no Info.plist — and `DishWatch/ (+…)` is a
        // worse identifier than one that admits what it is.
        let v = BuildInfo.main.shortVersion
        return "DishWatch/\(v.isEmpty ? "dev" : v) (+https://github.com/faeton/dishwatch)"
    }

    static func fetch(from url: URL) async throws -> Egress {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw EgressError.http(http.statusCode)
        }
        return try decode(data)
    }

    /// Split from `fetch` so the interesting half has tests. Every shape this
    /// has to survive — a renamed key, a missing `reverse`, an HTML error page
    /// served with a 200 — is a decode problem, not a networking one.
    static func decode(_ data: Data) throws -> Egress {
        do {
            return try JSONDecoder().decode(Egress.self, from: data)
        } catch let e as EgressError {
            throw e
        } catch {
            throw EgressError.notJSON
        }
    }

    /// One short clause for the panel. `URLError`'s own descriptions are
    /// sentences with their own punctuation, which read badly appended to
    /// "Could not check:".
    static func message(for error: Error) -> String {
        if let e = error as? EgressError { return e.errorDescription ?? "failed" }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet: return "this Mac is offline"
            case .timedOut:               return "the server did not answer in time"
            case .cannotFindHost, .dnsLookupFailed: return "the host could not be resolved"
            default: return u.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
