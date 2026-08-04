import Foundation

/// Link state drives the status dot + menu-bar icon color.
enum LinkState: String, Decodable, Sendable {
    case connected = "Connected"
    case weak      = "Weak"
    case disabled  = "Disabled"
    case offline   = "Offline"

    var isOnline: Bool { self == .connected || self == .weak }
}

/// One snapshot of dish + power state. Mirrors the Go `model.Dashboard` DTO that
/// the live provider (dishkit c-archive) will eventually decode — see
/// docs/roadmap.md. Today it's filled by `SampleProvider`.
struct DishData: Decodable, Sendable {
    var state: LinkState = .connected
    var signalScore: Int = 86

    // identity
    var uptimeHours: Double = 7.3
    var boots: Int = 4
    var hardwareShort: String = "Mini"
    var deviceId: String = "mini1_panda"
    var firmware: String = "2026.04.07"

    // throughput / link
    var downMbps: Double = 142.5
    var upMbps: Double = 14.2
    var pingMs: Double = 31
    var dropPct: Double = 0.2
    var noiseOK: Bool = true
    var downBarFrac: Double = 0.71  // vs nominal
    var upBarFrac: Double = 0.36

    // aim / gps / link
    var azimuthDeg: Double = 178
    var elevationDeg: Double = 62
    var gpsValid: Bool = true
    var gpsSats: Int = 12
    var ethMbps: Int = 1000

    // power
    var powerW: Double = 23.4
    var energyWhSinceBoot: Double = 71.2

    // sparkline series (oldest → newest)
    var pingSeries: [Double] = [33, 30, 36, 24, 31, 20, 29, 18, 26, 22, 33, 25, 16, 28, 19, 24]
    var pingAvg: Double = 33
    var downSeries: [Double] = [120, 150, 96, 188, 135, 198, 150, 205, 110, 170, 198, 130, 175, 120, 205, 160]
    var downMax: Double = 198
    var upSeries: [Double] = [10, 12, 9, 14, 8, 13, 7, 12, 9, 11, 13, 8, 12, 10, 14, 11]
    var upAvg: Double = 11
    var downAvg: Double = 96
    var powerSeries: [Double] = [22.6, 23.1, 22.2, 24.0, 21.8, 23.0, 21.2, 24.1, 22.5, 21.9, 23.0, 21.4, 22.6, 20.9, 23.4, 22.3]
    var powerAvg: Double = 22.8

    var dishAddr: String = "192.168.100.1"

    // ---- power-bank mode ----
    // Default off: battery UI only appears when the CLI has an anchor set
    // (`sl pb`). With pb disabled the dish is treated as on mains.
    var onBattery: Bool = false
    var bankAnchored: Bool = false   // a bank capacity/charge has been set
    var bankPct: Double = 78
    var bankWh: Double = 67          // full capacity
    var bankWhLeft: Double = 52.3
    var bankSecondsLeft: Int = 2 * 3600 + 18 * 60
    var anchoredAgoText: String = "12 m ago"

    var stateLabel: String { state.rawValue }

    /// Compact "Xh Ym" / "Ym" string for time-to-empty.
    var bankTimeLeftText: String {
        let h = bankSecondsLeft / 3600
        let m = (bankSecondsLeft % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// Resilient decoding: any missing key falls back to the struct's default, so a
// firmware/field change in `dishwatch json` never crashes the app.
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
