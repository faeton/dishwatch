import SwiftUI
import AppKit

@main
struct DishWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppState()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit DishWatch") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}

/// Accessory app: no Dock icon, lives only in the menu bar. Also hosts the
/// optional always-on-top pinned widget window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Everything below is development scaffolding and is compiled out of a
        // release build. It had no guard at all, which mattered more than it
        // sounds: `Render` pulls in the whole icon-candidate harness,
        // `NetProbe` opens raw BSD sockets and writes to a path taken from an
        // environment variable, and DISHWATCH_PROBE starts a *second*
        // HelperProvider alongside the app's own — two helpers contending the
        // same lock. All three were reachable by setting an env var on the
        // signed, sandboxed bundle.
        #if DEBUG
        if Render.runIfRequested() || NetProbe.runIfRequested() {
            NSApp.terminate(nil)
            return
        }
        // DISHWATCH_PROBE=1 → poll once, print, exit. Verifies that the real
        // helper decodes into DishData end-to-end.
        if ProcessInfo.processInfo.environment["DISHWATCH_PROBE"] != nil {
            Task { @MainActor in
                do {
                    // Exercise whatever the app itself would pick, not a
                    // hardcoded provider — the point of the probe is to verify
                    // the real path, and it silently stopped doing that once
                    // the helper became the preferred one.
                    let provider: DishProvider = HelperProvider.locateHelper() != nil
                        ? HelperProvider() : LiveProvider()
                    FileHandle.standardError.write(Data("PROBE via \(type(of: provider))\n".utf8))
                    let d = try await provider.poll()
                    FileHandle.standardError.write(Data("PROBE OK state=\(d.state.rawValue) signal=\(d.signalScore) down=\(d.downMbps) up=\(d.upMbps) ping=\(d.pingMs) power=\(d.powerW) onBattery=\(d.onBattery) bankAnchored=\(d.bankAnchored) pingSeries=\(d.pingSeries.count) hw=\(d.hardwareShort) fw=\(d.firmware)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("PROBE ERR \(error)\n".utf8))
                }
                NSApp.terminate(nil)
            }
            return
        }
        #endif
        NSApp.setActivationPolicy(.accessory)
    }
}
