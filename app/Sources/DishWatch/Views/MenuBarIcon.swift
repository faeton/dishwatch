import SwiftUI
import AppKit

/// The status-item glyph drawn in the menu bar. Resolves `IconMode` (with
/// `.auto` picking battery on bank, else signal) and optionally appends a value.
///
/// We render the glyph ourselves to an `NSImage` at the screen's backing scale
/// rather than letting `MenuBarExtra` rasterize a SwiftUI view — the latter
/// produced a muddy, half-black blob (esp. the dish arc).
///
/// Normally that image is a **template**: it keeps only its alpha, so the bar
/// tints it itself, white on dark and black on light, in appearances Apple has
/// not shipped yet. `AppState.colorThroughput` gives that up deliberately — a
/// coloured item cannot be a template — and takes on inking the readout by hand
/// per appearance. See `render(store:darkBar:)` and `DW.downBar(dark:)`.
///
/// Status colour still lives in the popover either way; the bar shows at most
/// the two throughput hues.
struct MenuBarLabel: View {
    @ObservedObject var store: AppState
    /// Which bar we are drawing on, and the reason this is read from the
    /// environment rather than from `NSApp.effectiveAppearance`: it has to
    /// re-run the body when the user switches appearance. A colour we sampled
    /// imperatively inside the renderer would be baked into a cached image that
    /// nothing invalidates, leaving black text on a black bar until some
    /// unrelated field happened to move. Only consulted when the readout is
    /// coloured — a template image needs no appearance at all.
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme != .light
        Image(nsImage: Self.cachedRender(store: store, darkBar: dark))
            // `.original` or the view layer re-flattens the colours we just
            // went to the trouble of drawing.
            .renderingMode(store.colorThroughput ? .original : .template)
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
        /// Both halves of the colour decision, because both change the pixels.
        ///
        /// `darkBar` in particular is not optional to key on: a coloured image
        /// is not a template, so the ink is baked in, and without this the cache
        /// would happily serve black-on-black across an appearance switch until
        /// some unrelated field moved. It is deliberately folded into `colored`
        /// being true — a template image draws the same bytes on either bar.
        let colored: Bool
        let darkBar: Bool
    }

    @MainActor private static var cacheKey: GlyphKey?
    @MainActor private static var cacheImage: NSImage?

    @MainActor
    static func cachedRender(store: AppState, darkBar: Bool) -> NSImage {
        let d = store.data
        let colored = store.colorThroughput
        let key = GlyphKey(
            mode: store.iconMode,
            onBattery: d.onBattery,
            bankPct: MenuBarIconContent.bankPercent(d),
            text: store.menuBarText,
            litBars: SignalBars.litBars(fraction: store.menuBarSignalFraction),
            scale: backingScale(),
            spark: store.showsMenuBarSpark ? MenuBarSpark.plotted(store.menuBarSparkValues) : nil,
            colored: colored,
            // Only meaningful when coloured; pinned otherwise so a monochrome
            // readout does not re-render on an appearance change it ignores.
            darkBar: colored && darkBar
        )
        if key == cacheKey, let img = cacheImage { return img }
        let img = render(store: store, darkBar: darkBar)
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
    static func render(store: AppState, darkBar: Bool) -> NSImage {
        let colored = store.colorThroughput
        // Monochrome keeps drawing in black: `isTemplate` throws the RGB away
        // and keeps only the alpha, so the ink's colour is irrelevant — it is
        // the shape that survives. Coloured has to pick a real ink, because
        // nothing downstream will pick one for us.
        let content = MenuBarIconContent(store: store,
                                         ink: colored ? (darkBar ? .white : .black) : .black,
                                         tinted: colored,
                                         darkBar: darkBar)
        let renderer = ImageRenderer(content: content)
        renderer.scale = backingScale()
        let img = renderer.nsImage ?? NSImage()
        // Template only while monochrome. This is the whole trade the setting
        // makes: a template adopts the bar's tint in every appearance for free,
        // and it can do that precisely because it has discarded the colours.
        img.isTemplate = !colored
        return img
    }
}

extension MenuBarField {
    /// The colour this field draws in when the coloured readout is on. `nil`
    /// means "the bar's own ink".
    ///
    /// Only the two throughput figures are tinted, and that is the point: they
    /// are a *pair*, adjacent, in the same unit, distinguished today by nothing
    /// but a `↓`/`↑` glyph at 11 pt. Colour is doing work there. Tinting ping,
    /// power and the rest as well would leave nothing distinguished — it would
    /// just be a multicoloured menu bar — and each extra hue is another one that
    /// has to stay legible on both appearances.
    ///
    /// The hues match the popover's throughput row, so the pairing is learned
    /// once and holds in both places.
    func tint(dark: Bool) -> Color? {
        switch self {
        case .down: return DW.downBar(dark: dark)
        case .up:   return DW.upBar(dark: dark)
        default:    return nil
        }
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
    /// Whether the throughput figures take their own hues instead of `ink`.
    var tinted: Bool = false
    /// Which appearance those hues are picked for. Ignored unless `tinted`.
    var darkBar: Bool = true

    var body: some View {
        let d = store.data
        let useBattery = d.onBattery && store.iconMode == .auto

        HStack(spacing: 4) {
            glyph(useBattery: useBattery, d: d)
            if store.showsMenuBarSpark {
                MenuBarSpark(values: store.menuBarSparkValues, color: ink)
            }

            ForEach(store.menuBarTexts) { item in
                Text(item.text)
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    // A field with no tint of its own falls back to the ink,
                    // which is also what every field does while `tinted` is
                    // off — so the monochrome path is unchanged, not merely
                    // equivalent.
                    .foregroundStyle((tinted ? item.field.tint(dark: darkBar) : nil) ?? ink)
            }
        }
        .frame(height: 15)
        .padding(.horizontal, 1)
        // A hairline shadow, only in coloured mode, and only because coloured
        // mode gave up the thing that made it unnecessary.
        //
        // A template image is composited by the bar against the bar's own
        // backdrop; ours is a flat bitmap laid over whatever the desktop
        // picture happens to be. Rendered against three wallpapers, the pale
        // one is the alarming case: it washes out not just the tints but the
        // *white ink* beside them, so a mis-read appearance takes the whole
        // readout with it rather than only the colours. The shadow does not
        // repair that — nothing at this size does — but it keeps a rim of
        // separation on every background tested, and it is what the system
        // itself draws behind menu-bar text over bright content.
        //
        // Direction follows the ink: a dark halo under light glyphs, a light
        // one under dark glyphs. Absent entirely when the image is a template,
        // where it would be flattened into the alpha mask and read as a smudge.
        .shadow(color: tinted ? (darkBar ? .black.opacity(0.5) : .white.opacity(0.6)) : .clear,
                radius: tinted ? 1 : 0, y: tinted ? 0.5 : 0)
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
        // `store.menuBarSignalFraction`, not `d.signalScore`: on a failed poll
        // the last good score is still sitting in `data`, and four lit bars over
        // a dead link is the same lie as a stale ping beside them.
        let bars = SignalBars(color: ink, height: 12, barWidth: 2.4,
                              fraction: store.menuBarSignalFraction)
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
            // No trace to draw — an unreachable dish, a failing poll, or the
            // first second after launch. A dashed midline keeps the item's width
            // (so it stays clickable) and reads as *no data*, where either
            // alternative reads as data: blank space looks like a rendering
            // fault, and the last good trace looks like a live link.
            guard pts.count > 1 else {
                var flat = Path()
                flat.move(to: CGPoint(x: 0, y: size.height / 2))
                flat.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(flat, with: .color(color),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .butt, dash: [2, 2]))
                return
            }
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
