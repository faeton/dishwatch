import SwiftUI
import AppKit

/// Candidate default menu-bar glyphs — vivid/colored, on-brand for a Starlink
/// monitor. Rendered (not template) so they keep their color in the bar. Used
/// by `Render` (DISHWATCH_ICONS=<dir>) to preview options before we wire one in
/// as the default `IconMode`.
enum IconCandidate: String, CaseIterable {
    case dishy        // Starlink "Dishy": tilted panel on a stem
    case waves        // broadcast dot + radiating arcs
    case parabola     // classic satellite dish
    case orbit        // planet + orbiting satellite
    case bolt         // signal bars with a status pip

    @ViewBuilder var glyph: some View {
        switch self {
        case .dishy:    GlyphDishy()
        case .waves:    GlyphWaves()
        case .parabola: GlyphParabola()
        case .orbit:    GlyphOrbit()
        case .bolt:     GlyphBarsPip()
        }
    }
}

/// Brand cyan gradient + soft glow shared by the colored candidates.
private struct CyanInk: ViewModifier {
    var glow: Bool = true
    func body(content: Content) -> some View {
        content
            .foregroundStyle(LinearGradient(
                colors: [Color(hex: 0x6FE9FF), Color(hex: 0x2BB4EC)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .shadow(color: glow ? Color(hex: 0x37D7FF).opacity(0.55) : .clear, radius: 1.4)
    }
}
private extension View { func cyanInk(glow: Bool = true) -> some View { modifier(CyanInk(glow: glow)) } }

private let cyanGrad = LinearGradient(
    colors: [Color(hex: 0x6FE9FF), Color(hex: 0x2BB4EC)],
    startPoint: .topLeading, endPoint: .bottomTrailing)

// MARK: - Candidates

/// Starlink "Dishy": tilted rounded-rect panel on a thin stem + base.
private struct GlyphDishy: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3.2, style: .continuous)
                .fill(cyanGrad)
                .frame(width: 15, height: 9)
                .overlay(RoundedRectangle(cornerRadius: 3.2, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 0.6))
                .rotationEffect(.degrees(-24))
                .offset(y: -2.5)
            Capsule().fill(cyanGrad).frame(width: 2, height: 7).offset(x: 1, y: 4)
            Capsule().fill(cyanGrad).frame(width: 8, height: 2).offset(y: 7.5)
        }
        .frame(width: 20, height: 18)
        .shadow(color: Color(hex: 0x37D7FF).opacity(0.5), radius: 1.3)
    }
}

/// Broadcast: solid dot with two radiating arcs (signal).
private struct GlyphWaves: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CornerArc().stroke(cyanGrad, style: .init(lineWidth: 2, lineCap: .round))
                .frame(width: 17, height: 17)
            CornerArc().stroke(cyanGrad.opacity(0.55), style: .init(lineWidth: 2, lineCap: .round))
                .frame(width: 11, height: 11)
            Circle().fill(cyanGrad).frame(width: 5.5, height: 5.5)
        }
        .frame(width: 18, height: 18, alignment: .bottomLeading)
        .shadow(color: Color(hex: 0x37D7FF).opacity(0.55), radius: 1.3)
    }
    private struct CornerArc: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.addArc(center: CGPoint(x: r.minX, y: r.maxY), radius: r.width,
                     startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            return p
        }
    }
}

/// Classic parabolic satellite dish: open ellipse + feed arm + stand.
private struct GlyphParabola: View {
    var body: some View {
        ZStack {
            // dish face (tilted ellipse)
            Ellipse().fill(cyanGrad)
                .frame(width: 13, height: 9)
                .rotationEffect(.degrees(-32))
                .offset(x: -1, y: -3)
            // feed arm + horn
            Circle().fill(cyanGrad).frame(width: 3, height: 3).offset(x: 5, y: -1)
            Capsule().fill(cyanGrad).frame(width: 1.6, height: 6).offset(x: 0, y: 4)
            Capsule().fill(cyanGrad).frame(width: 9, height: 1.8).offset(y: 7.5)
        }
        .frame(width: 20, height: 18)
        .shadow(color: Color(hex: 0x37D7FF).opacity(0.5), radius: 1.3)
    }
}

/// Planet with an orbiting satellite — "space" feel.
private struct GlyphOrbit: View {
    var body: some View {
        ZStack {
            Ellipse().stroke(cyanGrad.opacity(0.7), lineWidth: 1.6)
                .frame(width: 18, height: 9)
                .rotationEffect(.degrees(-20))
            Circle().fill(cyanGrad).frame(width: 8, height: 8)
            Circle().fill(.white).frame(width: 3.2, height: 3.2).offset(x: 7, y: -4)
        }
        .frame(width: 20, height: 18)
        .shadow(color: Color(hex: 0x37D7FF).opacity(0.5), radius: 1.3)
    }
}

/// Signal bars (familiar) but colored with a green status pip.
private struct GlyphBarsPip: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1).fill(cyanGrad)
                        .frame(width: 3, height: 5 + CGFloat(i) * 3.2)
                }
            }
            Circle().fill(Color(hex: 0x30D158)).frame(width: 5, height: 5)
                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.5))
                .offset(x: 3, y: -2)
        }
        .frame(width: 20, height: 16)
        .shadow(color: Color(hex: 0x37D7FF).opacity(0.45), radius: 1.2)
    }
}
