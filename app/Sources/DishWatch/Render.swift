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
            fields: UserDefaults.standard.array(forKey: "menuBarFields") as? [String],
            color: UserDefaults.standard.object(forKey: "colorThroughput") as? Bool
        )
        defer {
            UserDefaults.standard.set(saved.icon, forKey: "iconMode")
            UserDefaults.standard.set(saved.fields, forKey: "menuBarFields")
            UserDefaults.standard.set(saved.color, forKey: "colorThroughput")
        }
        let store = AppState(provider: SampleProvider())
        store.seed()
        // Pin the settings that this store's snapshots display, so the shots are
        // a function of the code rather than of whatever the last run left in
        // UserDefaults.
        store.iconMode = .signalBars
        store.menuBarFields = AppState.defaultFields
        var battery = DishData.sample; battery.onBattery = true; battery.bankAnchored = true

        // A release bundle's footer: version only, the short form.
        let releaseBuild = BuildInfo(shortVersion: "0.2.7", buildNumber: "89",
                                     channel: .release, sourceVersion: "v0.2.7")
        // And the long one — a dirty local build off a tag, which is the widest
        // this label ever gets and the case that decides whether the footer
        // still fits an IP, a status phrase and the Pin button.
        let devBuild = BuildInfo(shortVersion: "0.2.7", buildNumber: "89",
                                 channel: .dev, sourceVersion: "v0.2.7-1-gcdd29ad-dirty")
        snap(ConnectedPopover(d: store.data, showSettings: .constant(false), build: releaseBuild).environmentObject(store).frame(width: 392).background(DW.panel()).environment(\.colorScheme, .dark), dir, "connected")
        // The panel at its *widest* identity, which is the ordinary one.
        // `DishData.sample` carries `Mini` and `mini1_panda` — shorter than
        // anything a real dish reports — and that is why the hardware chip
        // shipped one release truncated to `Standard… · Self-a…` in the header
        // while every screenshot here looked fine. A shot of the long strings is
        // the only thing that makes a layout regression visible before a user
        // sees it.
        var long = DishData.sample
        long.hardwareShort = "Standard Gen3"
        long.hardwareAim = .motorized
        long.deviceId = "ut01000000-00000000-00ed07ca"
        long.firmware = "2026.04.07.mr77639.1"
        long.boots = 1326
        long.uptimeHours = 0.7
        // The widest service reading there is: `Business Plus · cleared to use
        // in motion` shares the identity column with the ID and the firmware,
        // and is longer than either.
        long.serviceClass = .businessPlus
        long.serviceMobility = .mobile
        snap(ConnectedPopover(d: long, showSettings: .constant(false), build: devBuild).environmentObject(store)
                .frame(width: 392).background(DW.panel()).environment(\.colorScheme, .dark),
             dir, "connected-long")
        // And at its *emptiest* identity: `"?"` is what DishData defaults to and
        // what an offline snapshot carries, so the chip and the backdrop both
        // draw nothing. The case exists because "draws nothing" is not the same
        // as "takes no space" — padding applied to an absent view at the call
        // site is still padding, and the failure it produces is a blank band
        // that no assertion would catch and no other shot would show.
        // The state this build was cut for: service stopped, with a cause. The
        // hero grows a wrapped red clause under a one-word label, and the
        // service line grows a `· metered` tail — two additions in the same
        // column, neither of which any other case draws. `inOcean` is the
        // longest phrase in `ServiceDisable`, so this is also the wrap test.
        var blocked = DishData.sample
        blocked.state = .disabled
        blocked.serviceDisable = .inOcean
        blocked.metered = true
        blocked.serviceClass = .businessPlus
        blocked.serviceMobility = .mobile
        snap(ConnectedPopover(d: blocked, showSettings: .constant(false), build: devBuild).environmentObject(store)
                .frame(width: 392).background(DW.panel()).environment(\.colorScheme, .dark),
             dir, "connected-blocked")
        var unknown = DishData.sample
        unknown.hardwareShort = "?"
        unknown.hardwareAim = .unknown
        // The same "draws nothing must also take no space" check for the
        // service line, which is a separate gate from the chip's: a stationary
        // dish reports no mobility class at all, so this case is not rare.
        unknown.serviceClass = .unknown
        unknown.serviceMobility = .unknown
        snap(ConnectedPopover(d: unknown, showSettings: .constant(false)).environmentObject(store)
                .frame(width: 392).background(DW.panel()).environment(\.colorScheme, .dark),
             dir, "connected-unknown")
        snap(BatteryPopover(d: battery, showSettings: .constant(false), showBankSetup: .constant(false)).environmentObject(store).frame(width: 392).background(DW.panel()).environment(\.colorScheme, .dark), dir, "battery")
        snap(CompactWidget(d: .sample, quality: .sample), dir, "compact")
        snap(BatterySetupSheet(d: .sample, onAnchor: { _, _ in }), dir, "setup")
        // `SettingsContent`, not `SettingsView`: ImageRenderer does not
        // rasterize a ScrollView's contents, so snapping the whole screen
        // produced a header over blank space — every control here lives inside
        // the scroller, so the harness was checking nothing at all.
        snap(SettingsContent(store: store)
                .frame(width: DW.settingsWidth).background(DW.panel())
                .environment(\.colorScheme, .dark),
             dir, "settings")

        // The hardware chip has three states and the popover shots only ever
        // show one of them — `DishData.sample` is a Mini, so nothing else here
        // renders the motorized case, or the unrecognised model that must come
        // out as a name with *no* aim clause after it.
        snap(VStack(alignment: .leading, spacing: 8) {
                HardwareChip(model: "Standard Gen2", aim: .motorized)
                HardwareChip(model: "Mini", aim: .manual)
                HardwareChip(model: "rev9_martian", aim: .unknown)
                HardwareChip(model: "?", aim: .unknown) // draws nothing at all
             }
             .padding(12).background(DW.panel()).environment(\.colorScheme, .dark),
             dir, "hardware")

        // The reboot confirmation. It lives behind `@State` in the popover, so
        // no other shot here can reach it — and it is the app's only
        // destructive action, which spent several releases as a
        // `.confirmationDialog` that could not receive a click at all. A
        // picture of the thing that replaced it is worth having.
        snap(ConfirmStrip(title: "Reboot the dish?",
                          message: "The connection will drop for ~1–2 minutes.",
                          confirmTitle: "Reboot")
                .padding(16).frame(width: 392).background(DW.panel())
                .environment(\.colorScheme, .dark),
             dir, "confirm")

        // The shared throughput row at its *hard* shape: both directions a few
        // Mbps and crossing constantly. `DishData.sample` is the easy shape —
        // download an order of magnitude up — where two hues are plenty, and it
        // is not the shape a roaming dish spends its day in. The download fill
        // weight exists for this picture; without a shot of it, a later change
        // to that number looks free.
        var tangled = DishData.sample
        tangled.downSeries = [3, 12, 1, 9, 20, 4, 7, 15, 2, 11, 6, 18, 3, 8, 13, 5]
        tangled.upSeries   = [5, 9, 4, 14, 7, 12, 3, 10, 16, 6, 9, 4, 11, 7, 2, 8]
        snap(ConnectedPopover(d: tangled, showSettings: .constant(false)).environmentObject(store)
                .frame(width: 392).background(DW.panel()).environment(\.colorScheme, .dark),
             dir, "tangled")

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
        // The coloured readout, on both bars.
        //
        // Every other bar shot above is a template image: one ink, tinted for
        // us, and it cannot be wrong on one appearance and right on the other.
        // This one is not — it is the single configuration where we choose the
        // pixels — so the failure it can have is a hue that reads on black and
        // turns to mud on white. That is invisible in a dark-only screenshot,
        // which is why both are here.
        for (name, dark) in [("dark", true), ("light", false)] {
            let s = AppState(provider: SampleProvider()); s.seed()
            s.iconMode = .signalBars
            s.menuBarFields = [.ping, .down, .up]
            s.colorThroughput = true
            snap(MenuBarIconContent(store: s, ink: dark ? .white : .black,
                                    tinted: true, darkBar: dark)
                    .padding(6)
                    .background(dark ? Color(white: 0.11) : Color(white: 0.9)),
                 dir, "bar-color-\(name)")
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
