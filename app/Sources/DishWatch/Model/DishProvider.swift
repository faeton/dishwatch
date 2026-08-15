import Foundation

/// Source of dish snapshots. The sample provider feeds the design's numbers so
/// the app runs anywhere; a future `LiveProvider` will call the Go core
/// (dishkit c-archive) behind this same protocol — see docs/roadmap.md.
///
/// `async throws` so the live provider can do off-main-actor cgo/network work
/// and surface failures (which `AppState` maps to an offline snapshot).
///
/// `window` is how many seconds of sparkline history to fetch (60–900, off the
/// dish's own ring). It is a per-poll argument rather than provider state
/// because the user can change it between two polls and the next frame has to
/// answer for the new one, not the previous.
protocol DishProvider: Sendable {
    func poll(window: Int) async throws -> DishData
}

extension DishProvider {
    func poll() async throws -> DishData { try await poll(window: 60) }
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
    func poll(window: Int) async throws -> DishData { throw Missing() }
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

    /// Deep enough to answer the widest window the UI offers. The sample series
    /// used to be 16 points long and got rolled one at a time, which was fine
    /// while every surface asked for the same window and useless the moment one
    /// could ask for 15 minutes — a demo build would have shown a 16-point trace
    /// under a "15 m" caption, which is the exact caption bug `seriesSeconds`
    /// exists to prevent.
    private static let depth = 900
    private var pings: [Double] = []
    private var downs: [Double] = []
    private var ups: [Double] = []
    private var watts: [Double] = []

    func poll(window: Int) async throws -> DishData {
        tick += 1
        var d = base

        // gentle jitter on headline numbers
        let wobble = sin(Double(tick) / 3)
        d.pingMs = max(12, (31 + wobble * 3).rounded())
        d.downMbps = (142.5 + wobble * 8).rounded(toPlaces: 1)
        d.powerW = (23.4 + wobble * 0.6).rounded(toPlaces: 1)
        d.signalScore = min(100, max(0, 86 + Int(wobble * 2)))

        seed()
        push(&pings, d.pingMs)
        push(&downs, d.downMbps)
        push(&ups, d.upMbps)
        push(&watts, d.powerW)

        let w = min(max(window, 60), Self.depth)
        d.pingSeries = Array(pings.suffix(w))
        d.downSeries = Array(downs.suffix(w))
        d.upSeries = Array(ups.suffix(w))
        d.powerSeries = Array(watts.suffix(w))
        d.seriesSeconds = d.pingSeries.count
        return d
    }

    /// Fill the rings once from the design's pattern, tiled — so the very first
    /// frame already has depth instead of drawing a single point.
    private func seed() {
        guard pings.isEmpty else { return }
        func tile(_ s: [Double]) -> [Double] {
            guard !s.isEmpty else { return [] }
            return (0..<Self.depth).map { s[$0 % s.count] }
        }
        pings = tile(base.pingSeries)
        downs = tile(base.downSeries)
        ups = tile(base.upSeries)
        watts = tile(base.powerSeries)
    }

    private func push(_ s: inout [Double], _ v: Double) {
        s.append(v)
        if s.count > Self.depth { s.removeFirst(s.count - Self.depth) }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let p = pow(10, Double(places))
        return (self * p).rounded() / p
    }
}
