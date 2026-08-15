import SwiftUI

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

/// DishWatch design tokens — mirrors DishWatch.dc.html ("deep-space vibrancy").
enum DW {
    // Accents
    static let cyan  = Color(hex: 0x37D7FF) // signal / brand
    static let down  = Color(hex: 0x4B8DF8) // download
    /// Upload. Violet, not the near-identical blue (`0x6FA8FF`) it used to be.
    /// The two were four points of hue apart, which was survivable while they
    /// only ever appeared in separate cells — and stopped being survivable the
    /// moment both series went onto one axis, where the colour is the *only*
    /// thing saying which trace is which.
    static let up    = Color(hex: 0xA78BFA)
    static let amber = Color(hex: 0xFFB340) // power / battery
    static let amberA = Color(hex: 0xFF9F0A)
    static let amberB = Color(hex: 0xFFC44D)
    static let green = Color(hex: 0x30D158) // connected / ok
    static let red   = Color(hex: 0xFF453A) // offline / error

    // Text on dark
    static let text = Color(hex: 0xEEF2F8)
    static func textA(_ a: Double) -> Color { text.opacity(a) }

    // Surfaces
    static let gaugeWell = Color(hex: 0x161B27)
    static let cellBG    = Color(hex: 0x141823) // rgba(20,24,35)
    static let hairline  = Color.white.opacity(0.09)

    /// Popover panel background — top→bottom dark gradient.
    static func panel(_ topAlpha: Double = 0.96, _ botAlpha: Double = 0.98) -> LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0x202534, alpha: topAlpha), Color(hex: 0x11141E, alpha: botAlpha)],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// Faint deep-space backdrop used by the menu-bar hero / icon showcase.
    static var space: RadialGradient {
        RadialGradient(
            colors: [Color(hex: 0x1A2546), Color(hex: 0x0A0F1F), Color(hex: 0x05070F)],
            center: UnitPoint(x: 0.3, y: 0.0), startRadius: 0, endRadius: 520
        )
    }

    static let amberFill = LinearGradient(colors: [amberA, amberB], startPoint: .leading, endPoint: .trailing)

    /// Crossfade for in-panel navigation (status ⇄ settings). Opacity only —
    /// height/slide animation inside a MenuBarExtra(.window) panel is janky.
    static let panelNav = Animation.easeInOut(duration: 0.16)

    /// Color for a 0–100 signal/health score: cyan/green → amber → red.
    static func scoreColor(_ score: Int) -> Color {
        switch score {
        case 75...:  return cyan
        case 50..<75: return amber
        default:      return red
        }
    }
}

extension View {
    /// Standard popover panel chrome: gradient fill, hairline border, rounded corners.
    func dwPanel(corner: CGFloat = 16) -> some View {
        self
            .background(DW.panel())
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
    }
}
