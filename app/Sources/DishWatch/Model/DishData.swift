import Foundation

/// Link state drives the status dot + menu-bar icon color.
enum LinkState: String, Decodable, Sendable {
    case connected = "Connected"
    case weak      = "Weak"
    case disabled  = "Disabled"
    case offline   = "Offline"

    var isOnline: Bool { self == .connected || self == .weak }
}

/// One snapshot of dish + power state. Mirrors the Go `Dashboard` DTO emitted by
/// `dishwatch json` — see dashboard.go.
///
/// **The memberwise defaults are deliberately neutral**, not the design's
/// numbers. They are what a missing field decodes to (see `init(from:)` below),
/// so anything plausible here would be indistinguishable from live data. The
/// mockup figures live in `DishData.sample` instead, which only `SampleProvider`
/// and the render harness construct. Sample data and decode fallbacks are two
/// different jobs; conflating them is how a dropped field ends up rendering
/// "142.5 Mbps" under a footer that reads "live".
// Equatable so AppState can skip republishing an identical snapshot, and so the
// menu-bar glyph cache has something to compare against. Without it every poll
// fired objectWillChange whether or not a single field had moved.
struct DishData: Decodable, Sendable, Equatable {
    var state: LinkState = .offline
    var signalScore: Int = 0

    // identity
    var uptimeHours: Double = 0
    var boots: Int = 0
    var hardwareShort: String = "?"
    var deviceId: String = ""
    var firmware: String = ""

    // throughput / link
    var downMbps: Double = 0
    var upMbps: Double = 0
    var pingMs: Double = 0
    var dropPct: Double = 0
    var noiseOK: Bool = false
    var downBarFrac: Double = 0  // vs nominal
    var upBarFrac: Double = 0

    // aim / gps / link
    var azimuthDeg: Double = 0
    var elevationDeg: Double = 0
    var gpsValid: Bool = false
    var gpsSats: Int = 0
    var ethMbps: Int = 0

    // power
    var powerW: Double = 0
    var energyWhSinceBoot: Double = 0
    /// Whether the samples behind `energyWhSinceBoot` actually cover this boot.
    /// The accumulator only integrates samples it retrieved, so after any gap
    /// the total is an under-count — and calling it "since boot" regardless is
    /// how a dish that had drawn ~900 Wh displayed "90.3 Wh since boot".
    var energyCoversBoot: Bool = false
    /// Seconds of samples integrated into the total, 0 when unknown.
    var energySeconds: Int64 = 0
    /// Mean draw across those samples, or 0 when no honest one exists — nothing
    /// counted yet, or a count and a total that cannot both be true.
    var energyAvgW: Double = 0

    // sparkline series (oldest → newest)
    var pingSeries: [Double] = []
    var pingAvg: Double = 0
    var downSeries: [Double] = []
    var downMax: Double = 0
    var upSeries: [Double] = []
    var upAvg: Double = 0
    var downAvg: Double = 0
    var powerSeries: [Double] = []
    var powerAvg: Double = 0
    /// How many samples the series above actually carry, straight from the
    /// helper. **Not** the window that was requested: the dish's ring is only as
    /// deep as the dish has been up, so a 15-minute request two minutes after a
    /// reboot comes back with 120 points. Every caption over a sparkline reads
    /// this, never `historyWindow`, or a freshly-booted dish gets a two-minute
    /// trace labelled "15 m".
    var seriesSeconds: Int = 0

    var dishAddr: String = ""

    /// Observed-session aggregates, or `nil` when the footer must not render.
    /// Decoded as one block — see `ObservedStats`.
    var observed: ObservedStats? = nil

    // ---- power-bank mode ----
    // Off unless the CLI has an anchor set (`sl pb`). With pb disabled the dish
    // is treated as on mains and no battery UI appears.
    var onBattery: Bool = false
    var bankAnchored: Bool = false   // a bank capacity/charge has been set
    var bankPct: Double = 0
    var bankWh: Double = 0           // full capacity
    var bankWhLeft: Double = 0
    var bankSecondsLeft: Int = 0
    var anchoredAgoText: String = ""

    var stateLabel: String { state.rawValue }

    /// Compact "Xh Ym" / "Ym" string for time-to-empty, or "—" when there is
    /// none. Zero is the sentinel `dashboard.go` writes when no honest average
    /// exists to divide by; printing it as "0m" states an imminent death that
    /// nothing measured.
    var bankTimeLeftText: String {
        guard bankSecondsLeft > 0 else { return "—" }
        let h = bankSecondsLeft / 3600
        let m = (bankSecondsLeft % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - Observed session

/// The `Observed` footer's data, decoded **all or nothing**.
///
/// Every other field on `DishData` degrades individually to a neutral default,
/// which is right for a metric grid where a zero reads as "no reading". It is
/// wrong here, and the reason is what the word "Observed" is for: the footer is
/// the app's honesty claim about long-window link quality (docs/macos-ui.md), so
/// a partially-decoded one states figures it cannot support. Per-field zero
/// defaults are not enough either — they handle a payload with none of these
/// keys, but a payload missing only `sessDownPeak` would still render
/// `peak ↓0 · 0 W` beside a real duration and a real ping.
///
/// This is not hypothetical version skew. `app/README.md` already warns that a
/// Homebrew `dishwatch` predating the `json` command won't work, and an older
/// CLI that emits the `sess*` block incompletely is exactly the expected shape
/// of that drift.
///
/// So: stored properties are non-optional `let`s with no defaults, which makes
/// the synthesised `Decodable` strict. Any missing or wrong-typed key throws,
/// `decode(from:)` maps that to `nil`, and the view hides the whole row. The
/// keys are flat in the payload rather than nested, so this decodes from the
/// same top-level container as `DishData` (see its `init(from:)`).
struct ObservedStats: Decodable, Sendable, Equatable {
    /// Below this the CLI has not collected enough samples to summarise, and
    /// emits zeros across the block. Mirrors `Stats.Ready()` in the Go side —
    /// if that threshold moves, this moves with it.
    static let minSeconds: Int64 = 120

    let seconds: Int64
    let coverage: Double
    let pingAvg: Double
    let cleanPct: Double
    let degradedPct: Double
    let darkPct: Double
    let outages: Int
    let outageSeconds: Int64
    let longestOutage: Int64
    let downPeak: Double
    let upPeak: Double
    let downBytes: Double
    let upBytes: Double
    let powerAvg: Double
    let powerPeak: Double
    /// Energy across exactly the samples this block describes. Not
    /// `DishData.energyWhSinceBoot`, which is a separate accumulator over a
    /// separate window — putting *that* on this block's line would state a
    /// total for a span it does not cover.
    let energyWh: Double

    enum CodingKeys: String, CodingKey {
        case seconds       = "obsSeconds"
        case coverage      = "obsCoverage"
        case pingAvg       = "sessPingAvg"
        case cleanPct      = "sessCleanPct"
        case degradedPct   = "sessDegradedPct"
        case darkPct       = "sessDarkPct"
        case outages       = "sessOutages"
        case outageSeconds = "sessOutageSeconds"
        case longestOutage = "sessLongestOutage"
        case downPeak      = "sessDownPeak"
        case upPeak        = "sessUpPeak"
        case downBytes     = "sessDownBytes"
        case upBytes       = "sessUpBytes"
        case powerAvg      = "sessPowerAvg"
        case powerPeak     = "sessPowerPeak"
        case energyWh      = "sessEnergyWh"
    }

    // `sessDropAvg` is deliberately absent. The Go side emits it, but
    // docs/macos-ui.md rules it out of the UI — a mean loss figure names a
    // state a moving dish is rarely in. Not decoding it means no view can
    // reach for it by accident.

    /// Returns `nil` rather than throwing, because every reason to fail here —
    /// old CLI, short session, garbage number — has the same correct response:
    /// don't draw the row.
    static func decode(from decoder: Decoder) -> ObservedStats? {
        guard let o = try? ObservedStats(from: decoder), o.isPresentable else { return nil }
        return o
    }

    /// A decoded block still has to be worth showing.
    ///
    /// The readiness check is the load-bearing half: zeros across the block are
    /// the CLI's "fewer than 120 samples" contract, not statistics, and nothing
    /// in the decode itself distinguishes them from a real all-zero session.
    ///
    /// The finiteness check is defence in depth and, measured, currently
    /// unreachable through JSON — `JSONDecoder` rejects an out-of-range literal
    /// before this ever runs. It is here for the in-process provider the
    /// roadmap's Phase 3 replaces the subprocess with, which will build this
    /// struct directly from a division that can produce a NaN rather than from
    /// a parsed document. Kept as a predicate on the value, not on the decode,
    /// so that path can use it too.
    var isPresentable: Bool {
        guard seconds >= Self.minSeconds else { return false }
        return [coverage, pingAvg, cleanPct, degradedPct, darkPct,
                downPeak, upPeak, downBytes, upBytes, powerAvg, powerPeak, energyWh]
            .allSatisfy(\.isFinite)
    }
}

// MARK: - Design sample

extension DishData {
    /// The design mockup's numbers, matching DishWatch.dc.html. Used by
    /// `SampleProvider` and the headless render harness so the app is
    /// demonstrable without a dish — never as a decode fallback.
    static let sample: DishData = {
        var d = DishData()
        d.state = .connected
        d.signalScore = 86
        d.uptimeHours = 7.3
        d.boots = 4
        d.hardwareShort = "Mini"
        d.deviceId = "mini1_panda"
        d.firmware = "2026.04.07"
        d.downMbps = 142.5
        d.upMbps = 14.2
        d.pingMs = 31
        d.dropPct = 0.2
        d.noiseOK = true
        d.downBarFrac = 0.71
        d.upBarFrac = 0.36
        d.azimuthDeg = 178
        d.elevationDeg = 62
        d.gpsValid = true
        d.gpsSats = 12
        d.ethMbps = 1000
        d.powerW = 23.4
        d.energyWhSinceBoot = 71.2
        d.pingSeries = [33, 30, 36, 24, 31, 20, 29, 18, 26, 22, 33, 25, 16, 28, 19, 24]
        d.pingAvg = 33
        d.downSeries = [120, 150, 96, 188, 135, 198, 150, 205, 110, 170, 198, 130, 175, 120, 205, 160]
        d.downMax = 198
        d.downAvg = 96
        d.upSeries = [10, 12, 9, 14, 8, 13, 7, 12, 9, 11, 13, 8, 12, 10, 14, 11]
        d.upAvg = 11
        d.powerSeries = [22.6, 23.1, 22.2, 24.0, 21.8, 23.0, 21.2, 24.1, 22.5, 21.9, 23.0, 21.4, 22.6, 20.9, 23.4, 22.3]
        d.powerAvg = 22.8
        d.seriesSeconds = d.pingSeries.count
        d.dishAddr = "192.168.100.1"
        // Built explicitly, never decoded — the whole point of splitting sample
        // data from decode fallbacks.
        d.observed = ObservedStats(
            seconds: 8040, coverage: 0.94, pingAvg: 29,
            cleanPct: 92, degradedPct: 6, darkPct: 2,
            outages: 11, outageSeconds: 143, longestOutage: 58,
            downPeak: 186, upPeak: 41,
            downBytes: 4.2e9, upBytes: 0.6e9,
            powerAvg: 23.8, powerPeak: 48.1, energyWh: 53.2)
        d.bankPct = 78
        d.bankWh = 67
        d.bankWhLeft = 52.3
        d.bankSecondsLeft = 2 * 3600 + 18 * 60
        d.anchoredAgoText = "12 m ago"
        return d
    }()
}

// MARK: - Decoding

// Missing keys fall back to the neutral defaults above, so a firmware or DTO
// change degrades a field to "no reading" instead of crashing the app — and,
// critically, instead of silently substituting a plausible number. `hasLoaded`
// and the offline state are what the UI gates on; a zero here is visibly a
// zero.
extension DishData {
    /// Contract version the app understands. Must match `DashboardSchemaVersion`
    /// in dashboard.go; scripts/check-contract.sh enforces it.
    static let expectedSchema = 1

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case state, signalScore, uptimeHours, boots, hardwareShort, deviceId, firmware
        case downMbps, upMbps, pingMs, dropPct, noiseOK, downBarFrac, upBarFrac
        case azimuthDeg, elevationDeg, gpsValid, gpsSats, ethMbps, powerW, energyWhSinceBoot
        case energyCoversBoot, energySeconds, energyAvgW
        case pingSeries, pingAvg, downSeries, downMax, downAvg, upSeries, upAvg, powerSeries, powerAvg
        case seriesSeconds
        case dishAddr, onBattery, bankAnchored, bankPct, bankWh, bankWhLeft, bankSecondsLeft, anchoredAgoText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = DishData()

        // Two keys are strict; everything else is lenient. The split is not
        // arbitrary.
        //
        // `schemaVersion` and `state` are the ones where a wrong value corrupts
        // meaning rather than detail. A missing or unknown `state` used to fall
        // back to `.offline` inside a `try?`, so a Go side that renamed a case
        // or added one — "Booting", say — rendered fresh, correct metrics under
        // an Offline header with a footer reading live, and nothing anywhere
        // reported a problem. Failing the decode makes AppState keep its last
        // good snapshot and say why.
        //
        // The metrics stay lenient because zero genuinely means "no reading"
        // for them, and because an additive change must not break an older app.
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        guard version == DishData.expectedSchema else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: c,
                debugDescription: "helper speaks dashboard schema \(version), this app expects \(DishData.expectedSchema)")
        }

        func s<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)) .flatMap { $0 } ?? fallback
        }
        d.state = try c.decode(LinkState.self, forKey: .state)
        d.signalScore = s(.signalScore, d.signalScore)
        d.uptimeHours = s(.uptimeHours, d.uptimeHours)
        d.boots = s(.boots, d.boots)
        d.hardwareShort = s(.hardwareShort, d.hardwareShort)
        d.deviceId = s(.deviceId, d.deviceId)
        d.firmware = s(.firmware, d.firmware)
        d.downMbps = s(.downMbps, d.downMbps)
        d.upMbps = s(.upMbps, d.upMbps)
        d.pingMs = s(.pingMs, d.pingMs)
        d.dropPct = s(.dropPct, d.dropPct)
        d.noiseOK = s(.noiseOK, d.noiseOK)
        d.downBarFrac = s(.downBarFrac, d.downBarFrac)
        d.upBarFrac = s(.upBarFrac, d.upBarFrac)
        d.azimuthDeg = s(.azimuthDeg, d.azimuthDeg)
        d.elevationDeg = s(.elevationDeg, d.elevationDeg)
        d.gpsValid = s(.gpsValid, d.gpsValid)
        d.gpsSats = s(.gpsSats, d.gpsSats)
        d.ethMbps = s(.ethMbps, d.ethMbps)
        d.powerW = s(.powerW, d.powerW)
        d.energyWhSinceBoot = s(.energyWhSinceBoot, d.energyWhSinceBoot)
        d.energyCoversBoot = s(.energyCoversBoot, d.energyCoversBoot)
        d.energySeconds = s(.energySeconds, d.energySeconds)
        d.energyAvgW = s(.energyAvgW, d.energyAvgW)
        d.pingSeries = s(.pingSeries, d.pingSeries)
        d.pingAvg = s(.pingAvg, d.pingAvg)
        d.downSeries = s(.downSeries, d.downSeries)
        d.downMax = s(.downMax, d.downMax)
        d.downAvg = s(.downAvg, d.downAvg)
        d.upSeries = s(.upSeries, d.upSeries)
        d.upAvg = s(.upAvg, d.upAvg)
        d.powerSeries = s(.powerSeries, d.powerSeries)
        d.powerAvg = s(.powerAvg, d.powerAvg)
        // Lenient like its neighbours, but with a fallback that stays true: a
        // helper too old to send this still returns *some* series, and their
        // length is what it observed. Zero here would caption a real trace "0 s".
        d.seriesSeconds = s(.seriesSeconds, d.pingSeries.count)
        d.dishAddr = s(.dishAddr, d.dishAddr)
        // Same decoder, not a nested container: the sess*/obs* keys are flat in
        // the payload. All-or-nothing, unlike every line above it.
        d.observed = ObservedStats.decode(from: decoder)
        d.onBattery = s(.onBattery, d.onBattery)
        d.bankAnchored = s(.bankAnchored, d.bankAnchored)
        d.bankPct = s(.bankPct, d.bankPct)
        d.bankWh = s(.bankWh, d.bankWh)
        d.bankWhLeft = s(.bankWhLeft, d.bankWhLeft)
        d.bankSecondsLeft = s(.bankSecondsLeft, d.bankSecondsLeft)
        d.anchoredAgoText = s(.anchoredAgoText, d.anchoredAgoText)
        self = d
    }
}

/// Which glyph the menu-bar status item draws.
///
/// `dataReadout` is gone. It was the only way to get a number into the bar, so
/// it had to masquerade as a glyph mode — choosing it meant giving up the signal
/// arc, and it could only ever show ping. Numbers are `MenuBarField`s now, which
/// makes "just the ping, no glyph" the ordinary combination `noGlyph` + `[.ping]`
/// rather than a special case. `AppState` migrates the stored value.
enum IconMode: String, CaseIterable, Identifiable {
    case signalBars = "Signal bars"
    case dishArc    = "Dish arc"
    case auto       = "Auto"   // battery on bank, else signal
    /// Numbers only. Spelled `noGlyph` rather than `none` so it never has to be
    /// disambiguated from `Optional.none` at a call site.
    case noGlyph    = "No glyph"
    var id: String { rawValue }
}

/// One value the status item can append after its glyph.
///
/// The order of `allCases` is the order they render in — left to right, most
/// asked-for first — so the bar layout does not depend on the order the user
/// happened to tick the boxes in, and does not jump around when one is toggled.
enum MenuBarField: String, CaseIterable, Identifiable, Codable {
    case pingSpark = "pingSpark"
    case ping      = "ping"
    case down      = "down"
    case up        = "up"
    case signal    = "signal"
    case power     = "power"
    case energy    = "energy"
    case battery   = "battery"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pingSpark: return "Ping graph"
        case .ping:      return "Ping"
        case .down:      return "Download"
        case .up:        return "Upload"
        case .signal:    return "Signal score"
        case .power:     return "Power draw"
        case .energy:    return "Energy measured"
        case .battery:   return "Battery %"
        }
    }

    /// Shown beside the title in Settings so the width cost is visible before
    /// the box is ticked, not after.
    var note: String? {
        switch self {
        case .pingSpark: return "redraws every poll"
        case .energy:    return "measured total, no window"
        case .battery:   return "only on a power bank"
        default:         return nil
        }
    }

    /// Throughput for the menu bar: one decimal below 10 Mbps, whole Mbps above.
    ///
    /// A flat `Int` rounding read as broken on an idle link — a dish doing
    /// 0.3 ↓ and 0.4 ↑ rendered `↓0 ↑0`, which says *nothing is flowing* about a
    /// link that is fine. It is the same trap docs/macos-ui.md records for mean
    /// throughput, where an idle dish averaging ~0 Mbps reads as a fault. The
    /// decimal is only spent where it carries that meaning: past 10 Mbps nobody
    /// reads the tenths, and the menu bar is the one surface where two glyphs of
    /// width is a real cost.
    ///
    /// Rounds *before* choosing the format, so 9.96 renders `10` rather than the
    /// wider and self-contradicting `10.0`.
    static func compactMbps(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r >= 10 ? "\(Int(r.rounded()))" : String(format: "%.1f", r)
    }

    /// What this field renders as, or nil when it has nothing to say right now
    /// (battery off a bank) or is not text at all (the sparkline).
    func text(_ d: DishData) -> String? {
        switch self {
        case .pingSpark: return nil
        case .ping:      return "\(Int(d.pingMs))ms"
        // Unit-less: the arrow already says which direction it is.
        case .down:      return "↓" + Self.compactMbps(d.downMbps)
        case .up:        return "↑" + Self.compactMbps(d.upMbps)
        case .signal:    return "\(d.signalScore)"
        case .power:     return "\(Int(d.powerW.rounded()))W"
        // Whole watt-hours: this is a running total, and its tenths change once
        // a minute at 30 W while costing width in the bar permanently.
        case .energy:    return d.energyWhSinceBoot > 0 ? "\(Int(d.energyWhSinceBoot.rounded()))Wh" : nil
        // Off a bank there is no percentage to show — and a 0% would read as a
        // flat battery rather than as "not on one".
        case .battery:   return d.bankAnchored ? "\(Int(d.bankPct))%" : nil
        }
    }
}
