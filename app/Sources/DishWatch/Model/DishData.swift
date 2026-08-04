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
struct DishData: Decodable, Sendable {
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

    var dishAddr: String = ""

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

    /// Compact "Xh Ym" / "Ym" string for time-to-empty.
    var bankTimeLeftText: String {
        let h = bankSecondsLeft / 3600
        let m = (bankSecondsLeft % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
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
        d.dishAddr = "192.168.100.1"
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
    enum CodingKeys: String, CodingKey {
        case state, signalScore, uptimeHours, boots, hardwareShort, deviceId, firmware
        case downMbps, upMbps, pingMs, dropPct, noiseOK, downBarFrac, upBarFrac
        case azimuthDeg, elevationDeg, gpsValid, gpsSats, ethMbps, powerW, energyWhSinceBoot
        case pingSeries, pingAvg, downSeries, downMax, downAvg, upSeries, upAvg, powerSeries, powerAvg
        case dishAddr, onBattery, bankAnchored, bankPct, bankWh, bankWhLeft, bankSecondsLeft, anchoredAgoText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = DishData()
        func s<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)) .flatMap { $0 } ?? fallback
        }
        d.state = s(.state, d.state)
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
        d.pingSeries = s(.pingSeries, d.pingSeries)
        d.pingAvg = s(.pingAvg, d.pingAvg)
        d.downSeries = s(.downSeries, d.downSeries)
        d.downMax = s(.downMax, d.downMax)
        d.downAvg = s(.downAvg, d.downAvg)
        d.upSeries = s(.upSeries, d.upSeries)
        d.upAvg = s(.upAvg, d.upAvg)
        d.powerSeries = s(.powerSeries, d.powerSeries)
        d.powerAvg = s(.powerAvg, d.powerAvg)
        d.dishAddr = s(.dishAddr, d.dishAddr)
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
enum IconMode: String, CaseIterable, Identifiable {
    case signalBars = "Signal bars"
    case dishArc    = "Dish arc"
    case dataReadout = "Data readout"
    case auto       = "Auto"   // battery on bank, else signal
    var id: String { rawValue }
}

enum DataReadoutKind { case ping, watts }
