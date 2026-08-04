import SwiftUI
import AppKit

/// Headless snapshot mode: when DISHWATCH_RENDER=<dir> is set, rasterize each
/// screen to a PNG and exit. Used to verify design fidelity without clicking
/// through the menu bar. Not part of normal app flow.
@MainActor
enum Render {
    static func runIfRequested() -> Bool {
        if let dir = ProcessInfo.processInfo.environment["DISHWATCH_ICONS"] {
            renderCandidates(dir); return true
        }
        guard let dir = ProcessInfo.processInfo.environment["DISHWATCH_RENDER"] else { return false }
        let store = AppState(provider: SampleProvider())
        store.seedSample()
        var battery = DishData(); battery.onBattery = true; battery.bankAnchored = true

        snap(ConnectedPopover(d: store.data, showSettings: .constant(false)).environmentObject(store).frame(width: 392).background(DW.panel()).environment(\.colorScheme, .dark), dir, "connected")
        snap(BatteryPopover(d: battery, showSettings: .constant(false)).environmentObject(store).frame(width: 392).background(DW.panel()).environment(\.colorScheme, .dark), dir, "battery")
        snap(CompactWidget(d: DishData()), dir, "compact")
        snap(BatterySetupSheet(d: DishData()), dir, "setup")
        snap(SettingsView().environmentObject(store), dir, "settings")

        // Menu-bar glyphs: render each icon mode as the black-ink silhouette the
        // template image uses, on a light bar, to verify shapes aren't blobs.
        for mode in IconMode.allCases {
            let s = AppState(provider: SampleProvider()); s.seedSample(); s.iconMode = mode
            snap(MenuBarIconContent(store: s)
                    .padding(6)
                    .background(Color(white: 0.9)),
                 dir, "icon-\(mode.rawValue.replacingOccurrences(of: " ", with: "-"))")
        }
        return true
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
