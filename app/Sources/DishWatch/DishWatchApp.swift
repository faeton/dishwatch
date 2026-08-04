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
        if Render.runIfRequested() {
            NSApp.terminate(nil)
            return
        }
        // DISHWATCH_PROBE=1 → poll the live provider once, print, exit. Verifies
        // the real `dishwatch json` decodes into DishData end-to-end.
        if ProcessInfo.processInfo.environment["DISHWATCH_PROBE"] != nil {
            Task { @MainActor in
                do {
                    let d = try await LiveProvider().poll()
                    FileHandle.standardError.write(Data("PROBE OK state=\(d.state.rawValue) signal=\(d.signalScore) down=\(d.downMbps) up=\(d.upMbps) ping=\(d.pingMs) power=\(d.powerW) onBattery=\(d.onBattery) bankAnchored=\(d.bankAnchored) pingSeries=\(d.pingSeries.count) hw=\(d.hardwareShort) fw=\(d.firmware)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("PROBE ERR \(error)\n".utf8))
                }
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.setActivationPolicy(.accessory)
    }
}
