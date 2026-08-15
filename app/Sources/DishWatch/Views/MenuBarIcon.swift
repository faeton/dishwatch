import SwiftUI
import AppKit

/// The status-item glyph drawn in the menu bar. Resolves `IconMode` (with
/// `.auto` picking battery on bank, else signal) and optionally appends a value.
///
/// We render the glyph ourselves to a **template** `NSImage` at the screen's
/// backing scale rather than letting `MenuBarExtra` rasterize a SwiftUI view —
/// the latter produced a muddy, half-black blob (esp. the dish arc). A template
/// image is crisp and tints itself to the menu bar (white on dark, black on
/// light). Status color lives in the popover, where the bar can't show it.
struct MenuBarLabel: View {
    @ObservedObject var store: AppState

    var body: some View {
        Image(nsImage: Self.cachedRender(store: store))
            .renderingMode(.template)
            .help(tooltip)
    }

    /// The tooltip has to carry the staleness, because the glyph cannot. This is
    /// the app's primary surface and it was the only one with no honesty gate:
    /// on a failed poll it kept displaying the last signal score and ping
    /// indefinitely, reading "Offline · 18 ms · 4↓ Mbps · sig 78" — an offline
    /// state quoting live-looking numbers of unbounded age.
    private var tooltip: String {
        let d = store.data
        switch store.quality {
        case .loading:
            return "DishWatch — connecting…"
        case .sample:
            return "DishWatch — sample data, not a real dish"
        case .brokenInstall(let why):
            return "DishWatch — \(why)"
        case .disabled:
            return "DishWatch — the dish reports service disabled"
        case .offline:
            return "DishWatch — no dish found at \(d.dishAddr)"
        case .stale:
            let age = store.lastGoodAgoText.map { " (\($0))" } ?? ""
            return "DishWatch — not responding. Last reading\(age): \(Int(d.pingMs)) ms · sig \(d.signalScore)"
        case .live:
            // Carries every headline number regardless of which ones the user
            // put in the bar — the tooltip is where the ones they left out live.
            return "\(d.stateLabel) · \(Int(d.pingMs)) ms · \(Int(d.downMbps))↓ \(Int(d.upMbps))↑ Mbps · sig \(d.signalScore)"
        }
    }

    /// Everything the glyph is actually a function of. The icon has ~5 inputs
    /// while `AppState` publishes ~40 fields, so without this the menu bar
    /// re-rasterized a SwiftUI view on the main actor on *every* poll —
    /// once a second, forever, whether or not anything visible had moved. That
    /// was the app's dominant idle cost.
    /// **Every field here must be something the renderer actually consumes.**
    ///
    /// A key that is coarser than the drawing freezes the icon: the glyph
    /// changes, the key does not, and the stale image is served forever. That is
    /// not hypothetical — this key first shipped with `signalScore / 5` and
    /// rounded spark samples while the views drew the raw `Double`s, so a score
    /// moving 12 → 13 (which lights a bar) and a trace inverting within one
    /// millisecond (which flips the whole slope, since the spark auto-ranges)
    /// were both invisible to it. The fix is not a finer bucket, it is keying on
    /// the drawn quantity and having the view draw from the same value.
    private struct GlyphKey: Equatable {
        let mode: IconMode
        let onBattery: Bool
        /// Whole percent — and `MenuBarIconContent` fills the battery from this
        /// same rounded value, so key and drawing cannot disagree.
        let bankPct: Int
        /// Every appended value, already laid out. One string covers the whole
        /// readout no matter how many fields are on.
        let text: String
        /// Lit bars, not the score: that is all `SignalBars` derives from it.
        let litBars: Int
        let scale: CGFloat
        /// Nil unless the ping sparkline is on. When it is, the shape is part of
        /// the image, so this is the exact array `MenuBarSpark` will plot.
        let spark: [Double]?
    }

    @MainActor private static var cacheKey: GlyphKey?
    @MainActor private static var cacheImage: NSImage?

    @MainActor
    static func cachedRender(store: AppState) -> NSImage {
        let d = store.data
        let key = GlyphKey(
            mode: store.iconMode,
            onBattery: d.onBattery,
            bankPct: MenuBarIconContent.bankPercent(d),
            text: store.menuBarText,
            litBars: SignalBars.litBars(fraction: Double(d.signalScore) / 100),
            scale: backingScale(),
            spark: store.showsMenuBarSpark ? MenuBarSpark.plotted(d.pingSeries) : nil
        )
        if key == cacheKey, let img = cacheImage { return img }
        let img = render(store: store)
        cacheKey = key
        cacheImage = img
        return img
    }

    /// `NSScreen.main` is the screen holding the key window, and an `.accessory`
    /// app usually has none — so it returned nil or the wrong display on a
    /// multi-monitor setup and the icon rasterized at the wrong scale. Take the
    /// sharpest attached display instead; over-rendering is free here, and a
    /// soft menu-bar icon is the one artefact everybody notices.
    @MainActor
    private static func backingScale() -> CGFloat {
        NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
    }

    @MainActor
    static func render(store: AppState) -> NSImage {
        let renderer = ImageRenderer(content: MenuBarIconContent(store: store))
        renderer.scale = backingScale()
        let img = renderer.nsImage ?? NSImage()
        img.isTemplate = true   // adopt the menu bar's tint, both appearances
        return img
    }
}

/// The actual icon contents, drawn in a single opaque ink so the template image
/// keeps shape via the alpha channel (RGB is ignored once `isTemplate = true`).
struct MenuBarIconContent: View {
    @ObservedObject var store: AppState
    /// Any opaque colour: `isTemplate` keeps only the alpha channel, so the bar
    /// tints it itself. Overridable so Settings can preview the real thing on a
    /// dark panel — black ink on the panel would be an invisible preview, and a
    /// re-implemented one would drift from what the bar actually draws.
    var ink: Color = .black

    var body: some View {
        let d = store.data
        let useBattery = d.onBattery && store.iconMode == .auto

        HStack(spacing: 4) {
            glyph(useBattery: useBattery, d: d)
            if store.showsMenuBarSpark {
                MenuBarSpark(values: d.pingSeries, color: ink)
            }

            ForEach(store.menuBarTexts) { item in
                Text(item.text)
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(ink)
            }
        }
        .frame(height: 15)
        .padding(.horizontal, 1)
    }

    /// The glyph, or nothing.
    ///
    /// `.noGlyph` with no field to show would leave a status item of literally
    /// zero width — invisible, and with nothing left to click to reach Settings
    /// and undo it. So an empty readout falls back to the signal bars: the only
    /// unrecoverable configuration is the one the UI refuses to produce.
    /// The battery fill, quantised to whole percent — the same value `GlyphKey`
    /// stores, so the cache cannot skip a redraw the eye would catch. Lossless
    /// in practice: the glyph is 20 pt wide, so 1% is 0.2 pt.
    static func bankPercent(_ d: DishData) -> Int { Int(d.bankPct.rounded()) }

    @ViewBuilder
    private func glyph(useBattery: Bool, d: DishData) -> some View {
        let bars = SignalBars(color: ink, height: 12, barWidth: 2.4,
                              fraction: Double(d.signalScore) / 100)
        if useBattery {
            BatteryGlyph(fraction: Double(Self.bankPercent(d)) / 100,
                         color: ink, width: 20, height: 11)
        } else {
            switch store.iconMode {
            case .dishArc:
                DishArcGlyph(color: ink)
            case .noGlyph:
                if store.menuBarTexts.isEmpty && !store.showsMenuBarSpark { bars }
            default: // signalBars, or auto-on-mains
                bars
            }
        }
    }
}

/// A ping trace small enough for the menu bar.
///
/// Not `Spark`: that one fills under the line with a gradient, which a template
/// image flattens into a grey haze, and it auto-ranges over however many points
/// it is handed. This takes a fixed tail and draws a bare stroke, so the shape
/// survives being reduced to an alpha mask at 11 pt.
struct MenuBarSpark: View {
    /// Points drawn. Wider than this and the trace stops being readable in a
    /// menu bar; narrower and a spike lands between samples.
    static let samples = 26

    /// The exact array this view plots, given a full ping series.
    ///
    /// The single definition of the trace, called by both the view and
    /// `MenuBarLabel.GlyphKey`. It has to be one function: the key quantised to
    /// whole milliseconds while the view drew raw `Double`s, and because the
    /// trace auto-ranges over its own min and max, `[10.1, 10.4]` and
    /// `[10.4, 10.1]` are opposite full-height slopes that shared a key.
    ///
    /// A tail, not the whole series, because the popover's window control can
    /// widen `pingSeries` to 900 points: 26 pt of menu bar holds about 26 of
    /// them, and keying on the rest would churn the cache for pixels that do not
    /// exist.
    static func plotted(_ series: [Double]) -> [Double] {
        series.suffix(samples).map { ($0).rounded() }
    }

    var values: [Double]
    var color: Color
    var width: CGFloat = 26
    var height: CGFloat = 11

    var body: some View {
        let pts = Self.plotted(values)
        Canvas { ctx, size in
            guard pts.count > 1 else { return }
            let mn = pts.min() ?? 0
            let mx = pts.max() ?? 1
            // A flat trace is a real reading, not a divide-by-zero: floor the
            // range so it draws as a line through the middle instead of pinning
            // to the top edge.
            let rng = max(mx - mn, 0.0001)
            let stepX = size.width / CGFloat(pts.count - 1)
            let inset: CGFloat = 1
            var path = Path()
            for (i, v) in pts.enumerated() {
                let t = mx - mn < 0.0001 ? 0.5 : (v - mn) / rng
                let y = size.height - inset - CGFloat(t) * (size.height - 2 * inset)
                let p = CGPoint(x: CGFloat(i) * stepX, y: y)
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: width, height: height)
    }
}

/// Battery outline glyph with fill + nub.
struct BatteryGlyph: View {
    var fraction: Double
    var color: Color
    var width: CGFloat = 22
    var height: CGFloat = 11
    var body: some View {
        HStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(DW.text.opacity(0.75), lineWidth: 1.3)
                .overlay(
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color)
                            .padding(1.5)
                            .frame(width: max(2, (g.size.width - 3) * fraction))
                    },
                    alignment: .leading
                )
                .frame(width: width, height: height)
            Capsule().fill(DW.text.opacity(0.7)).frame(width: 1.6, height: height * 0.36)
        }
    }
}

/// Concentric-arc "dish" glyph that waves by strength.
struct DishArcGlyph: View {
    var color: Color
    var size: CGFloat = 14
    /// Absolute, not proportional, because at menu-bar sizes the stroke has to
    /// land on whole pixels to stay crisp — scaling it would blur the glyph at
    /// exactly the size it matters most. Callers drawing it large (the app
    /// icon) pass a proportional width instead, or the arcs vanish to hairlines.
    var strokeWidth: CGFloat = 1.8
    var body: some View {
        ZStack(alignment: .bottom) {
            Circle().fill(color).frame(width: size * 0.32, height: size * 0.32)
            Arc().stroke(color, lineWidth: strokeWidth)
                .frame(width: size * 0.72, height: size * 0.72)
            Arc().stroke(color.opacity(0.45), lineWidth: strokeWidth)
                .frame(width: size * 1.05, height: size * 1.05)
        }
        .frame(width: size, height: size, alignment: .bottom)
        .clipped()
    }
    private struct Arc: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.addArc(center: CGPoint(x: r.midX, y: r.maxY),
                     radius: r.width / 2, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            return p
        }
    }
}
