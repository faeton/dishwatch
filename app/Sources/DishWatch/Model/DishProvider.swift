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

/// Used when a release build cannot find its embedded helper — which should be
/// impossible, since `app/Makefile` refuses to assemble a bundle without one.
///
/// It exists so that "impossible" degrades into a visible, accurate error rather
/// than into `SampleProvider`, whose animated 142.5 Mbps is indistinguishable
/// from a working dish. Failing loudly on a packaging mistake is worth more than
/// a dashboard that looks fine and is fiction.
struct MissingHelperProvider: DishProvider {
    struct Missing: LocalizedError {
        var errorDescription: String? {
            "DishWatch could not find its helper. The app bundle looks incomplete — reinstalling should fix it."
        }
    }
    func poll() async throws -> DishData { throw Missing() }
}

/// Deterministic sample data matching the design mock-up, with light per-tick
/// jitter so sparklines feel alive in a demo.
///
/// Development only — `AppState` never selects it in a release build. Its
/// numbers are the design's, not the dish's, and they animate; anything that
/// renders them must say so.
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
