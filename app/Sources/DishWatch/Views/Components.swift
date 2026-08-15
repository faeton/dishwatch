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

// MARK: - Sparkline

/// Area + line sparkline, auto-ranged to its values. Matches the SVG polylines
/// in the design.
struct Spark: View {
    var values: [Double]
    var color: Color
    var fill: Bool = true
    var lineWidth: CGFloat = 1.4

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if fill, pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.33), color.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                }
                Path { p in
                    for (i, pt) in pts.enumerated() {
                        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let mn = values.min() ?? 0
        let mx = values.max() ?? 1
        let rng = max(mx - mn, 0.0001)
        let stepX = size.width / CGFloat(values.count - 1)
        let pad: CGFloat = 3
        return values.enumerated().map { i, v in
            let t = (v - mn) / rng
            let y = size.height - pad - CGFloat(t) * (size.height - 2 * pad)
            return CGPoint(x: CGFloat(i) * stepX, y: y)
        }
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
