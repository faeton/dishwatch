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
            return "\(d.stateLabel) · \(Int(d.pingMs)) ms · \(Int(d.downMbps))↓ Mbps · sig \(d.signalScore)"
        }
    }

    /// Everything the glyph is actually a function of. The icon has ~5 inputs
    /// while `AppState` publishes ~40 fields, so without this the menu bar
    /// re-rasterized a SwiftUI view on the main actor on *every* poll —
    /// once a second, forever, whether or not anything visible had moved. That
    /// was the app's dominant idle cost.
    private struct GlyphKey: Equatable {
        let mode: IconMode
        let showValue: Bool
        let onBattery: Bool
        let bankPct: Int
        let headline: String
        let signalBucket: Int
        let scale: CGFloat
    }

    @MainActor private static var cacheKey: GlyphKey?
    @MainActor private static var cacheImage: NSImage?

    @MainActor
    static func cachedRender(store: AppState) -> NSImage {
        let d = store.data
        let key = GlyphKey(
            mode: store.iconMode,
            showValue: store.showValueNextToIcon,
            onBattery: d.onBattery,
            bankPct: Int(d.bankPct),
            headline: store.headlineValue,
            // The arc is drawn in fifths; sub-bucket changes are invisible.
            signalBucket: d.signalScore / 5,
            scale: backingScale()
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
    private let ink = Color.black   // any opaque color; template uses alpha only

    var body: some View {
        let d = store.data
        let mode = store.iconMode
        let useBattery = d.onBattery && mode == .auto

        HStack(spacing: 4) {
            glyph(mode: mode, useBattery: useBattery, d: d)
            // Data-readout mode IS the number; don't also append the value.
            if store.showValueNextToIcon && mode != .dataReadout && !useBattery {
                Text(store.headlineValue)
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(ink)
            }
        }
        .frame(height: 15)
        .padding(.horizontal, 1)
    }

    @ViewBuilder
    private func glyph(mode: IconMode, useBattery: Bool, d: DishData) -> some View {
        if useBattery {
            BatteryGlyph(fraction: d.bankPct / 100, color: ink, width: 20, height: 11)
        } else {
            switch mode {
            case .dataReadout:
                Text("\(Int(d.pingMs))ms")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ink)
            case .dishArc:
                DishArcGlyph(color: ink)
            default: // signalBars, or auto-on-mains
                SignalBars(color: ink, height: 12, barWidth: 2.4, fraction: Double(d.signalScore) / 100)
            }
        }
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
