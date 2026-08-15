import SwiftUI
import AppKit

/// Gear menu in popover headers: Settings, refresh, Quit. Centralizes the app
/// commands an accessory app can't put in a (nonexistent) main menu.
struct AppMenuButton: View {
    @Binding var showSettings: Bool
    var refresh: () -> Void = {}

    var body: some View {
        Menu {
            Button("Settings…") { showSettings = true }
            Button("Refresh now", action: refresh)
            Divider()
            Button("Quit DishWatch") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12)).foregroundStyle(DW.textA(0.6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .help("Settings & quit")
    }
}

// MARK: - Dish glyph + hardware chip

/// The dish itself, drawn as vectors.
///
/// Drawn rather than shipped as an image asset, and deliberately: SpaceX's
/// product renders and the Starlink marks are theirs, and a Store submission is
/// the wrong place to be carrying someone else's product photography. A
/// silhouette we own is also the only version that takes a tint, scales from a
/// chip to a menu-bar glyph, and diffs as text.
///
/// **One outline covers every current model, and honestly.** The Mini and both
/// Standards are all flat rectangular panels on a stem — they differ in size,
/// not in shape — so a single silhouette is a true picture of any of them. The
/// generation is written beside it in words rather than mimed in geometry a
/// reader would have to already know the product line to decode.
struct DishGlyph: View {
    var color: Color = DW.cyan
    /// Height of the glyph. Every dimension below is a fraction of it, so the
    /// shape is the same picture at 14 points and at 40.
    var size: CGFloat = 18
    var glow: Bool = true

    var body: some View {
        // Flat and wide, with a small corner radius. The panel is the whole
        // silhouette — a taller box on a thicker stem reads as a lollipop at
        // chip size, which is what the first pass of this drew.
        let u = size / 18
        ZStack {
            RoundedRectangle(cornerRadius: 1.8 * u, style: .continuous)
                .fill(color)
                .frame(width: 16 * u, height: 6 * u)
                .overlay(RoundedRectangle(cornerRadius: 1.8 * u, style: .continuous)
                    .strokeBorder(.white.opacity(0.3), lineWidth: 0.5 * u))
                .rotationEffect(.degrees(-22))
                .offset(y: -3.5 * u)
            Capsule().fill(color).frame(width: 1.6 * u, height: 8 * u).offset(x: 0.5 * u, y: 3.5 * u)
            Capsule().fill(color).frame(width: 8 * u, height: 1.6 * u).offset(y: 7.8 * u)
        }
        .frame(width: 20 * u, height: 18 * u)
        .shadow(color: glow ? color.opacity(0.45) : .clear, radius: 1.3 * u)
        .accessibilityHidden(true) // the chip beside it says all of this in words
    }
}

/// Which dish this is, and who points it — a picture, the model, and the answer
/// in words.
///
/// The aim half is the reason the chip exists. "Standard" was the whole of what
/// the app ever said about the hardware, and it is the one label that cannot
/// answer *do I have to go out and turn this thing myself* — Gen2 and Gen3 are
/// both "Standard" and only one of them aims itself. Nothing else on any screen
/// answered it either.
///
/// Renders nothing when there is no model to name (`"?"`, or an offline
/// snapshot with no reading at all), and drops the aim half alone when the
/// model is one the helper's table cannot place. A shrug is a better answer
/// than a guess when the guess sends someone up a mast.
struct HardwareChip: View {
    var model: String
    var aim: DishAim

    /// Whether there is a model to draw at all.
    ///
    /// Static and internal because callers need it *before* they lay the chip
    /// out: an `if` inside this view makes the chip draw nothing, but padding
    /// applied to it at the call site is still padding, so an unknown dish left
    /// a blank band where the chip would have been. The rule has to be asked
    /// once and answered the same way in both places — `"?"` is what
    /// `DishData` defaults to and what an offline snapshot carries.
    static func hasModel(_ model: String) -> Bool { !model.isEmpty && model != "?" }

    private var hasModel: Bool { Self.hasModel(model) }

    var body: some View {
        if hasModel {
            HStack(spacing: 6) {
                DishGlyph(size: 15)
                Text(model)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DW.textA(0.8))
                if aim != .unknown {
                    Text("·").foregroundStyle(DW.textA(0.3))
                    HStack(spacing: 3.5) {
                        Image(systemName: aim.symbol).font(.system(size: 8.5))
                        Text(aim.label).font(.system(size: 11))
                    }
                    .foregroundStyle(DW.textA(0.55))
                }
            }
            // Shrinks before it truncates. Not a guarantee that it *never*
            // truncates — the model is whatever string the dish reports, and a
            // long enough one runs out of column even at 82%. It is a
            // guarantee that the ordinary long case (`Standard Gen3 ·
            // Self-aiming`, ~185 pt against the hero's ~270) stays whole, which
            // is what the header placement could not manage.
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(Color.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Dish")
            .accessibilityValue(aim == .unknown ? model : "\(model), \(aim.label)")
        }
    }
}

// MARK: - Sparkline

/// One plotted series inside a `Spark`.
struct SparkTrace {
    /// Prefix the row uses in its legend and its scrub readout — `↓`, `↑`, or
    /// nothing for a chart with only one line. It lives here so a row that
    /// drops an absent series cannot label the traces it still draws wrongly.
    var symbol: String = ""
    var values: [Double]
    var color: Color
    /// Whether this trace gets the gradient under it. The second trace of a
    /// pair does not: a low line inside another trace's fill dissolves into it,
    /// which is how a real 14 Mbps upload comes to read as *no upload*.
    var filled: Bool = true
    /// Stroke width override. The unfilled trace of a pair carries a little
    /// more, since the fill is no longer there to say it exists.
    var width: CGFloat? = nil
    /// How strongly the gradient under a filled trace starts.
    ///
    /// The filled trace of a *pair* wants more than a lone one does, and this
    /// is the knob that makes two crossing series readable. Hue alone does not:
    /// when download and upload run at similar rates the two lines cross a
    /// dozen times across 24 points of height, and at that size "the blue one"
    /// and "the violet one" are a colour-matching exercise. With a body under
    /// one of them they stop being two lines of different colours and become an
    /// area and a line — a difference in *kind*, which survives the crossings,
    /// small sizes, and a reader who cannot separate the hues at all.
    var fillOpacity: Double = 0.33
}

/// Area + line sparkline, auto-ranged to its values. Matches the SVG polylines
/// in the design.
///
/// Plots one *or more* traces. Two rules make the multi-trace case honest, and
/// both are the whole reason it isn't just two `Spark`s stacked:
///
/// - **One vertical range across every trace.** Per-trace auto-ranging would
///   draw a 14 Mbps upload at the same height as a 143 Mbps download, which is
///   the exact class of true-number/false-impression defect docs/macos-ui.md
///   opens with.
/// - **Traces are right-aligned, never stretched.** `LastN` clamps each of the
///   dish's rings independently, so two series that describe the same window
///   can arrive with different lengths. Both end at *now* on the right edge and
///   a shorter one simply starts further in; scaling it to the full width would
///   silently relabel its samples as older than they are.
struct Spark: View {
    /// Where the bottom of the chart sits.
    ///
    /// `auto` is the sparkline default and is right for ping and power, whose
    /// news *is* the variation: a 20–36 ms ping is worth a full-height trace.
    ///
    /// `zero` is for quantities with a true zero, where the news is magnitude.
    /// Auto-ranging throughput draws a rock-steady 140–143 Mbps link as a
    /// rollercoaster, and — worse on a shared axis — a download and upload that
    /// happen to sit close together become two full-height traces of noise,
    /// which is utilization drawn as if it were amplitude. That is the reading
    /// this row exists to avoid.
    enum Baseline { case auto, zero }

    var traces: [SparkTrace]
    var fill: Bool = true
    var lineWidth: CGFloat = 1.4
    var baseline: Baseline = .auto
    /// Column to mark with a rule and a dot per trace, or nil for none. See
    /// `span` for what a column is.
    var marker: Int? = nil

    init(values: [Double], color: Color, fill: Bool = true, lineWidth: CGFloat = 1.4) {
        self.init(traces: [SparkTrace(values: values, color: color)], fill: fill, lineWidth: lineWidth)
    }

    init(traces: [SparkTrace], fill: Bool = true, lineWidth: CGFloat = 1.4,
         baseline: Baseline = .auto, marker: Int? = nil) {
        self.traces = traces
        self.fill = fill
        self.lineWidth = lineWidth
        self.baseline = baseline
        self.marker = marker
    }

    private static let pad: CGFloat = 3

    /// Columns are one-second steps across the chart: column 0 is the oldest
    /// sample the *widest* trace carries and `span` is the newest, i.e. now.
    /// The dish records one sample per second, so a column distance is also an
    /// age in seconds — which is what the scrub readout quotes.
    static func span(_ traces: [SparkTrace]) -> Int {
        max(0, (traces.map(\.values.count).max() ?? 0) - 1)
    }

    /// The sample a trace shows at `column`, or nil when its ring does not
    /// reach that far back.
    ///
    /// A non-finite value is *not a sample*, and this is the one choke point
    /// every reader goes through — the marker dot, the scrub readout, and its
    /// `Int` conversion, which would trap on one. Unreachable through JSON,
    /// which cannot carry a NaN at all; kept for the same reason
    /// `ObservedStats.isPresentable` keeps its finiteness check, which is the
    /// in-process provider that replaces the subprocess, where these numbers
    /// arrive from a division rather than from a parsed document.
    static func sample(_ t: SparkTrace, at column: Int, span: Int) -> Double? {
        let i = t.values.count - 1 - (span - column)
        guard t.values.indices.contains(i), t.values[i].isFinite else { return nil }
        return t.values[i]
    }

    /// The column nearest a horizontal position, clamped to the chart.
    static func column(atX x: CGFloat, width: CGFloat, span: Int) -> Int {
        guard span > 0, width > 0 else { return 0 }
        let c = (x / width * CGFloat(span)).rounded()
        return min(span, max(0, Int(c)))
    }

    var body: some View {
        let span = Self.span(traces)
        let bounds = self.bounds
        GeometryReader { geo in
            ZStack {
                ForEach(traces.indices, id: \.self) { i in
                    trace(traces[i], in: geo.size, span: span, bounds: bounds)
                }
                if let marker, span > 0 {
                    markerLayer(marker, in: geo.size, span: span, bounds: bounds)
                }
            }
        }
    }

    /// The shared vertical range. Every trace is measured against this, which
    /// is only meaningful because the traces a row combines share a unit.
    /// Non-finite values are excluded rather than clamped: one NaN in the range
    /// makes every coordinate derived from it NaN, which is a whole chart of
    /// invalid geometry from a single bad sample.
    private var bounds: (min: Double, max: Double) {
        let all = traces.flatMap(\.values).filter(\.isFinite)
        guard let mn = all.min(), let mx = all.max() else { return (0, 1) }
        // `min(0, mn)` rather than a flat 0: pinning the floor above a value
        // would draw it below the frame, which is a worse failure than a
        // baseline that is not quite zero.
        return baseline == .zero ? (Swift.min(0, mn), mx) : (mn, mx)
    }

    @ViewBuilder
    private func trace(_ t: SparkTrace, in size: CGSize, span: Int, bounds: (min: Double, max: Double)) -> some View {
        let pts = points(t, in: size, span: span, bounds: bounds)
        if pts.count > 1 {
            ZStack {
                if fill, t.filled {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [t.color.opacity(t.fillOpacity), t.color.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                }
                Path { p in
                    for (i, pt) in pts.enumerated() {
                        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                    }
                }
                .stroke(t.color, style: StrokeStyle(lineWidth: t.width ?? lineWidth,
                                                    lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// The scrub rule, plus a dot on each trace that has a sample there.
    private func markerLayer(_ marked: Int, in size: CGSize, span: Int, bounds: (min: Double, max: Double)) -> some View {
        // Clamped, because the column outlives the span it was measured
        // against: a poll landing mid-drag can hand back a shorter ring, and an
        // unclamped rule would then be drawn outside the chart, over the
        // trailing figure that describes it.
        let column = min(span, max(0, marked))
        let x = CGFloat(column) / CGFloat(span) * size.width
        return ZStack {
            Path { p in
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
            }
            .stroke(DW.text.opacity(0.3), lineWidth: 1)
            ForEach(traces.indices, id: \.self) { i in
                if let v = Self.sample(traces[i], at: column, span: span) {
                    Circle()
                        .fill(traces[i].color)
                        .frame(width: 5, height: 5)
                        .position(x: x, y: y(v, in: size, bounds: bounds))
                }
            }
        }
    }

    private func points(_ t: SparkTrace, in size: CGSize, span: Int, bounds: (min: Double, max: Double)) -> [CGPoint] {
        guard t.values.count > 1, span > 0 else { return [] }
        let stepX = size.width / CGFloat(span)
        let first = span - (t.values.count - 1)
        // A non-finite sample is skipped, not plotted at some substitute
        // height: the line bridges the gap, which is what a sparkline already
        // does for a second the dish never recorded.
        return t.values.enumerated().compactMap { i, v in
            guard v.isFinite else { return nil }
            return CGPoint(x: CGFloat(first + i) * stepX, y: y(v, in: size, bounds: bounds))
        }
    }

    private func y(_ v: Double, in size: CGSize, bounds: (min: Double, max: Double)) -> CGFloat {
        let rng = max(bounds.max - bounds.min, 0.0001)
        let t = (v - bounds.min) / rng
        return size.height - Self.pad - CGFloat(t) * (size.height - 2 * Self.pad)
    }
}

// MARK: - Signal gauge

/// Circular score gauge — a true stroked arc (no annulus seam) filling to
/// `score`, over a neutral track, with the number + label in the well.
struct SignalGauge: View {
    var score: Int
    var size: CGFloat = 78

    var body: some View {
        let frac = Double(min(100, max(0, score))) / 100
        let color = DW.scoreColor(score)
        let lw = size * 0.09
        ZStack {
            Circle()
                .stroke(DW.text.opacity(0.09), lineWidth: lw)
            Circle()
                .trim(from: 0, to: frac)
                .stroke(color, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 3) {
                Text("\(score)")
                    .font(.system(size: size * 0.31, weight: .bold)).monospacedDigit()
                    .foregroundStyle(DW.text)
                Text("SIGNAL")
                    .font(.system(size: size * 0.11, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(DW.textA(0.45))
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal")
        .accessibilityValue("\(score) out of 100")
    }
}

// MARK: - Status dot

struct StatusDot: View {
    var color: Color
    var size: CGFloat = 9
    var pulse: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = true

    private var animating: Bool { pulse && !reduceMotion }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.7), radius: size * 0.6)
            .opacity(animating && on ? 1 : (animating ? 0.35 : 1))
            .animation(animating ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : nil, value: on)
            .onAppear { if animating { on.toggle() } }
    }
}

// MARK: - Signal bars glyph (icon + popover header)

struct SignalBars: View {
    var color: Color = DW.cyan
    var height: CGFloat = 13
    var barWidth: CGFloat = 2.5
    /// 0–1 fraction of bars lit; remaining drawn faint.
    var fraction: Double = 0.78
    var bars: Int = 4

    /// How many bars this fraction lights. Exposed because the menu-bar glyph
    /// cache has to key on what is *drawn*: the bar count is the only thing the
    /// score affects here, and any key coarser or finer than it is wrong in one
    /// direction or the other.
    static func litBars(fraction: Double, bars: Int = 4) -> Int {
        Int((Double(bars) * fraction).rounded())
    }

    var body: some View {
        let lit = Self.litBars(fraction: fraction, bars: bars)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < lit ? color : DW.text.opacity(0.28))
                    .frame(width: barWidth, height: barHeight(i))
            }
        }
        .frame(height: height)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let t = CGFloat(i + 1) / CGFloat(bars)
        return height * (0.38 + 0.62 * t)
    }
}

// MARK: - Section label

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
            .foregroundStyle(DW.textA(0.42))
    }
}

// MARK: - Pills / buttons

struct DWButton: View {
    var title: String
    var prominent: Bool = false
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? Color(hex: 0x04121B) : DW.text)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(prominent ? DW.cyan : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Top radial glow used at the top of popovers.
struct TopGlow: View {
    var color: Color
    var height: CGFloat = 80
    var body: some View {
        RadialGradient(colors: [color.opacity(0.16), .clear],
                       center: .top, startRadius: 0, endRadius: height * 1.6)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }
}
