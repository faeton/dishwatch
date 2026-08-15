#if DEBUG
// Development scaffolding: excluded from release builds.
//
// This file is a build-time / diagnostic tool, not a feature. It used to be
// compiled into the shipped bundle because app/Makefile built `-c debug`, which
// made every guard like this one inert. See docs/roadmap.md "Cut before
// submission".

import SwiftUI
import AppKit

/// Headless snapshot mode: when DISHWATCH_RENDER=<dir> is set, rasterize each
/// screen to a PNG and exit. Used to verify design fidelity without clicking
/// through the menu bar. Not part of normal app flow.
@MainActor
enum Render {
    static func runIfRequested() -> Bool {
        if let path = ProcessInfo.processInfo.environment["DISHWATCH_APPICON"] {
            renderAppIcon(to: path); return true
        }
        if let dir = ProcessInfo.processInfo.environment["DISHWATCH_ICONS"] {
            renderCandidates(dir); return true
        }
        guard let dir = ProcessInfo.processInfo.environment["DISHWATCH_RENDER"] else { return false }
        // The harness drives real `AppState`s, whose settings persist through
        // `didSet` — so rendering the icon and readout variants below rewrote
        // the developer's own menu-bar preferences to whatever the last loop
        // iteration happened to set. Snapshot and put them back.
        let saved = (
            icon: UserDefaults.standard.string(forKey: "iconMode"),
            fields: UserDefaults.standard.array(forKey: "menuBarFields") as? [String]
        )
        defer {
            UserDefaults.standard.set(saved.icon, forKey: "iconMode")
            UserDefaults.standard.set(saved.fields, forKey: "menuBarFields")
        }
        let store = AppState(provider: SampleProvider())
        store.seed()
        // Pin the settings that this store's snapshots display, so the shots are
        // a function of the code rather than of whatever the last run left in
        // UserDefaults.
        store.iconMode = .signalBars
        store.menuBarFields = AppState.defaultFields
        var battery = DishData.sample; battery.onBattery = true; battery.bankAnchored = true

        snap(ConnectedPopover(d: store.data, showSettings: .constant(false)).environmentObject(store).frame(width: 392).background(DW.panel()).environment(\.colorScheme, .dark), dir, "connected")
        snap(BatteryPopover(d: battery, showSettings: .constant(false), showBankSetup: .constant(false)).environmentObject(store).frame(width: 392).background(DW.panel()).environment(\.colorScheme, .dark), dir, "battery")
        snap(CompactWidget(d: .sample, quality: .sample), dir, "compact")
        snap(BatterySetupSheet(d: .sample, onAnchor: { _, _ in }), dir, "setup")
        // `SettingsContent`, not `SettingsView`: ImageRenderer does not
        // rasterize a ScrollView's contents, so snapping the whole screen
        // produced a header over blank space — every control here lives inside
        // the scroller, so the harness was checking nothing at all.
        snap(SettingsContent(store: store)
                .frame(width: 392).background(DW.panel()).environment(\.colorScheme, .dark),
             dir, "settings")

        // Menu-bar glyphs: render each icon mode as the black-ink silhouette the
        // template image uses, on a light bar, to verify shapes aren't blobs.
        for mode in IconMode.allCases {
            let s = AppState(provider: SampleProvider()); s.seed(); s.iconMode = mode
            s.menuBarFields = []
            snap(MenuBarIconContent(store: s)
                    .padding(6)
                    .background(Color(white: 0.9)),
                 dir, "icon-\(mode.rawValue.replacingOccurrences(of: " ", with: "-"))")
        }

        // Readout combinations. The bar is the surface with the least room and
        // the most ways to be configured, and the sparkline in particular is
        // drawn with `Canvas` — worth a snapshot to confirm it survives being
        // flattened into a template image rather than becoming a smudge.
        // An idle-but-healthy link: the case whole-Mbps rounding rendered as
        // `↓0 ↑0`, i.e. as a dead link. It is also the *common* case — a dish
        // nobody is streaming through sits here — so it belongs in the harness
        // beside the busy one rather than only in a unit test.
        var idle = DishData.sample
        idle.downMbps = 0.3
        idle.upMbps = 0.4

        let readouts: [(String, IconMode, Set<MenuBarField>, DishData)] = [
            ("default",  .signalBars, AppState.defaultFields, .sample),
            ("tput",     .signalBars, [.down, .up], .sample),
            ("spark",    .signalBars, [.pingSpark, .ping], .sample),
            ("numbers",  .noGlyph,    [.pingSpark, .ping, .down, .up], .sample),
            ("all",      .dishArc,    Set(MenuBarField.allCases), .sample),
            ("idle",     .signalBars, [.pingSpark, .ping, .down, .up], idle),
        ]
        for (name, mode, fields, data) in readouts {
            let s = AppState(provider: SampleProvider()); s.seed(data)
            s.iconMode = mode; s.menuBarFields = fields
            snap(MenuBarIconContent(store: s).padding(6).background(Color(white: 0.9)),
                 dir, "bar-\(name)")
        }
        return true
    }

    /// Renders the 1024×1024 app icon (`DISHWATCH_APPICON=<file.png>`), from
    /// which `make icon` builds the `.icns`.
    ///
    /// It draws the app's own `DishArcGlyph` on the panel gradient rather than
    /// using stock art, so the icon and the menu bar cannot drift apart.
    ///
    /// **Deliberately no Starlink or SpaceX mark.** Guideline 5.2 is the single
    /// highest rejection risk for this app (docs/roadmap.md), and the icon is
    /// the most conspicuous place to trip it. A dish arc is a dish arc.
    ///
    /// This is a functional placeholder, not finished art — it exists so the
    /// bundle is complete and signable, and so the 1024 asset the Store
    /// requires has a source rather than being a one-off export nobody can
    /// reproduce. Replacing it is a design decision.
    private static func renderAppIcon(to path: String) {
        // macOS icons sit in a rounded square inset from the canvas; drawing to
        // the full 1024 makes the app look oversized next to its neighbours.
        let canvas: CGFloat = 1024, inset: CGFloat = 100
        let tile = canvas - inset * 2
        let glyph = tile * 0.62
        let icon = ZStack {
            RoundedRectangle(cornerRadius: tile * 0.2237, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x101725), Color(hex: 0x05080F)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: tile * 0.2237, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 3))
            // The glyph is bottom-anchored and clipped by design — its content
            // fills only the lower half of its own frame — so left centred it
            // sits visibly low in the tile. Lift it by a quarter of its height
            // to centre the ink rather than the box.
            DishArcGlyph(color: DW.cyan, size: glyph, strokeWidth: glyph * 0.045)
                .shadow(color: DW.cyan.opacity(0.5), radius: 44)
                .offset(y: -glyph * 0.25)
        }
        .frame(width: tile, height: tile)
        .padding(inset)
        .frame(width: canvas, height: canvas)

        let renderer = ImageRenderer(content: icon)
        renderer.scale = 1
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("app icon render failed\n".utf8)); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("wrote \(path)\n".utf8))
    }

    /// Preview each candidate glyph on a dark + light menu bar, plus a contact
    /// sheet of all of them, so we can pick a vivid default.
    private static func renderCandidates(_ dir: String) {
        let dark = Color(hex: 0x1C1C1E)   // dark menu bar
        let light = Color(hex: 0xE9E9EA)  // light menu bar
        for c in IconCandidate.allCases {
            let row = HStack(spacing: 0) {
                c.glyph.frame(width: 36, height: 22).background(dark)
                c.glyph.frame(width: 36, height: 22).background(light)
            }
            snap(row, dir, "cand-\(c.rawValue)")
        }
        // Contact sheet: all candidates side by side on each bar, scaled up 3×
        // with a label row so the shapes are easy to judge.
        func cellRow(_ bg: Color) -> some View {
            HStack(spacing: 10) {
                ForEach(IconCandidate.allCases, id: \.self) { c in
                    c.glyph.frame(width: 30, height: 22)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10).background(bg)
        }
        let labels = HStack(spacing: 10) {
            ForEach(IconCandidate.allCases, id: \.self) { c in
                Text(c.rawValue).font(.system(size: 7, weight: .medium))
                    .foregroundStyle(.gray).frame(width: 44)
            }
        }.padding(.horizontal, 7).background(Color.white)
        let strip = VStack(spacing: 0) { cellRow(dark); cellRow(light); labels }
            .scaleEffect(2).frame(width: 740, height: 184)
        snap(strip, dir, "candidates-all")
        FileHandle.standardError.write(Data("wrote \(IconCandidate.allCases.count) candidates to \(dir)\n".utf8))
    }

    private static func snap<V: View>(_ view: V, _ dir: String, _ name: String) {
        let renderer = ImageRenderer(content: view.fixedSize(horizontal: false, vertical: true))
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed: \(name)\n".utf8)); return
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? png.write(to: url)
        FileHandle.standardError.write(Data("wrote \(url.path)\n".utf8))
    }
}

#endif
