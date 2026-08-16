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
    // Panel widths
    /// The status panel. Sized for the metric grid and the sparklines.
    static let panelWidth: CGFloat = 392
    /// Settings, which is wider on purpose.
    ///
    /// It shares no layout with the status panel — no gauge, no 2×2 grid, no
    /// charts — and its rows are the one place in the app that carry a control,
    /// a title, a grey note *and* a live value on a single line. At 392 those
    /// four were fighting: the notes crowded the titles and the previews on the
    /// right had nowhere to sit. Nothing else in the app needs to match this
    /// number, because nothing else is on screen at the same time as it.
    static let settingsWidth: CGFloat = 468

    // Accents
    static let cyan  = Color(hex: 0x37D7FF) // signal / brand
    static let down  = Color(hex: 0x4B8DF8) // download
    /// Upload. Violet, not the near-identical blue (`0x6FA8FF`) it used to be.
    /// The two were four points of hue apart, which was survivable while they
    /// only ever appeared in separate cells — and stopped being survivable the
    /// moment both series went onto one axis, where the colour is the *only*
    /// thing saying which trace is which.
    ///
    /// Muted from the first violet it got (`0xA78BFA`), which was the most
    /// saturated colour on a panel whose whole palette is quiet: beside cyan
    /// ping and amber power it read as an alert rather than as a second
    /// throughput line. The hue is what separates it from download, so the hue
    /// stays and the chroma goes — same ~40° of separation, none of the shout.
    static let up    = Color(hex: 0x9B90D9)
    /// Menu-bar variants of the two throughput hues.
    ///
    /// Neither panel colour survives the move, and the first attempt reused
    /// `down`/`up` for exactly the wrong reason — they look correct in
    /// isolation, and they are never in isolation. The figure standing beside
    /// them is the bar's own ink. The panel hues were tuned *for a panel*, `up`
    /// deliberately quietened so it would not shout beside cyan and amber on a
    /// muted surface; the menu bar is the opposite problem, 11 pt next to white
    /// over a photograph.
    ///
    /// Both branches are pushed further from mid-tone than legibility against a
    /// flat bar would need, because the menu bar is frequently neither black nor
    /// white: it is translucent, and a vivid desktop picture shows through it.
    ///
    /// Contrast ratios, all WCAG, against a named background — a bare ratio with
    /// no background is not a measurement:
    ///
    /// | ink | vs `#1C1C1E` dark bar | vs `#2E6FC0` blue wallpaper |
    /// |---|---|---|
    /// | system white | 17.0 | 5.1 |
    /// | `down` `#4B8DF8` (panel hue, first attempt) | 5.2 | 2.3 |
    /// | `downBar(dark:)` `#A9D6FF` | 13.0 | 3.3 |
    ///
    /// The first attempt reused the panel hues and shipped at roughly a third of
    /// the contrast of the white figure standing next to them — "almost not
    /// seen". Hue cannot rescue a blue number on a blue bar, so the fix is on
    /// the luminance axis, which still works when the background may be any
    /// colour: near-white on the dark branch, near-black on the light one, each
    /// keeping only enough chroma to say which direction it is.
    ///
    /// The light branch is therefore *dark* ink — the mirror of the branch above
    /// it, not more of the same. Reading this table as "these are pale tints"
    /// and correcting the code to match would put pastels on a white bar.
    ///
    /// **The `dark` flag is the weak link, and it is honest to say so here.**
    /// It comes from `@Environment(\.colorScheme)`, which tracks the app and
    /// system appearance rather than the bar. Those usually agree and can
    /// disagree — a light system with a dark wallpaper behind the bar, or the
    /// reverse. A template image never had to care; these two palettes are
    /// opposites, so a wrong flag is not "faded" but "invisible". That is the
    /// standing cost of the setting, which is why it is opt-in and why the
    /// toggle says the bar stops matching light and dark by itself.
    static func downBar(dark: Bool) -> Color {
        dark ? Color(hex: 0xA9D6FF) : Color(hex: 0x0B47B8)
    }
    static func upBar(dark: Bool) -> Color {
        dark ? Color(hex: 0xDCD2FF) : Color(hex: 0x4A3A96)
    }

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
