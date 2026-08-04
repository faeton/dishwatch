import Foundation

/// Source of dish snapshots. The sample provider feeds the design's numbers so
/// the app runs anywhere; a future `LiveProvider` will call the Go core
/// (dishkit c-archive) behind this same protocol — see docs/roadmap.md.
///
/// `async throws` so the live provider can do off-main-actor cgo/network work
/// and surface failures (which `AppState` maps to an offline snapshot).
protocol DishProvider: Sendable {
    func poll() async throws -> DishData
}

/// Deterministic sample data matching DishWatch.dc.html, with light per-tick
/// jitter so sparklines/clock feel alive in a demo.
final class SampleProvider: DishProvider, @unchecked Sendable {
    private let base = DishData.sample
    private var tick = 0

    func poll() async throws -> DishData {
        tick += 1
        var d = base

        // gentle jitter on headline numbers
        let wobble = sin(Double(tick) / 3)
        d.pingMs = max(12, (31 + wobble * 3).rounded())
        d.downMbps = (142.5 + wobble * 8).rounded(toPlaces: 1)
        d.powerW = (23.4 + wobble * 0.6).rounded(toPlaces: 1)
        d.signalScore = min(100, max(0, 86 + Int(wobble * 2)))

        // advance the series rings
        d.pingSeries = rolled(base.pingSeries, next: d.pingMs)
        d.downSeries = rolled(base.downSeries, next: d.downMbps)
        d.powerSeries = rolled(base.powerSeries, next: d.powerW)
        d.upSeries = rolled(base.upSeries, next: d.upMbps)
        return d
    }

    private func rolled(_ s: [Double], next: Double) -> [Double] {
        Array(s.dropFirst()) + [next]
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let p = pow(10, Double(places))
        return (self * p).rounded() / p
    }
}
