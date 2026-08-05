import SwiftUI
import Combine
import ServiceManagement

/// App-wide observable state: the latest snapshot, user settings, and the poll
/// loop. UI views observe this.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var data = DishData()
    /// Last poll error, if any. Non-nil → the popover/icon should read "stale".
    @Published private(set) var lastError: String?
    /// False until the first poll completes — lets the UI avoid showing
    /// placeholder numbers as if they were real.
    @Published private(set) var hasLoaded = false

    // settings (persisted to UserDefaults)
    @Published var iconMode: IconMode { didSet { defaults.set(iconMode.rawValue, forKey: "iconMode") } }
    @Published var showValueNextToIcon: Bool { didSet { defaults.set(showValueNextToIcon, forKey: "showValue") } }
    @Published var pinnedWidget: Bool {
        didSet { defaults.set(pinnedWidget, forKey: "pinned"); pinnedController.setVisible(pinnedWidget) }
    }
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin"); applyLaunchAtLogin() }
    }
    @Published var refreshInterval: Int {
        didSet { defaults.set(refreshInterval, forKey: "refresh"); restartPolling() }
    }
    /// Demo-only: force the popover into battery layout regardless of real power.
    @Published var simulateBattery: Bool {
        didSet { Task { await refresh() } }
    }
    /// Why the last launch-at-login change didn't take, if it didn't.
    @Published private(set) var launchAtLoginError: String?
    private var applyingLaunchAtLogin = false

    private let provider: DishProvider
    private let defaults = UserDefaults.standard
    private var pollTask: Task<Void, Never>?
    private lazy var pinnedController = PinnedPanelController(store: self)

    /// Live (real dish) by default when the `dishwatch` binary is found; falls
    /// back to sample data otherwise so the app still runs.
    let isLive: Bool

    init(provider: DishProvider? = nil) {
        if let provider {
            self.provider = provider
            self.isLive = provider is LiveProvider
        } else if LiveProvider.locateBinary() != nil {
            self.provider = LiveProvider()
            self.isLive = true
        } else {
            self.provider = SampleProvider()
            self.isLive = false
        }
        self.iconMode = IconMode(rawValue: defaults.string(forKey: "iconMode") ?? "") ?? .signalBars
        self.showValueNextToIcon = defaults.object(forKey: "showValue") as? Bool ?? true
        self.pinnedWidget = defaults.object(forKey: "pinned") as? Bool ?? false
        self.launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
        self.refreshInterval = defaults.object(forKey: "refresh") as? Int ?? 1
        self.simulateBattery = false
        restartPolling()
        pinnedController.setVisible(pinnedWidget)
    }

    deinit { pollTask?.cancel() }

    /// The value shown next to the icon and used by the gauge.
    var headlineValue: String {
        if data.onBattery { return "\(Int(data.bankPct))%" }
        switch iconMode {
        case .dataReadout: return "\(Int(data.pingMs))ms"
        default:           return "\(data.signalScore)"
        }
    }

    /// One poll: fetch, apply demo override, keep last-good on failure.
    /// For the headless render path only: present sample data as if loaded.
    func seedSample() { data = .sample; hasLoaded = true }

    func refresh() async {
        do {
            var d = try await provider.poll()
            if simulateBattery { d.onBattery = true; d.bankAnchored = true }
            data = d
            lastError = nil
        } catch {
            // keep the last good snapshot but mark it offline + stale
            var d = data
            d.state = .offline
            data = d
            lastError = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Reboot the dish via `dishwatch reboot` (live only). Triggers an immediate
    /// poll afterwards so the UI reflects the drop. No-op on sample data.
    func reboot() async {
        guard let live = provider as? LiveProvider else { return }
        do { try await live.reboot() } catch { lastError = error.localizedDescription }
        await refresh()
    }

    /// Register/unregister the app as a macOS login item.
    ///
    /// This used to swallow the error, which made the toggle a liar: outside a
    /// real bundle `SMAppService.mainApp` has no bundle identifier to register,
    /// so it threw every time and the switch sat there showing ON having done
    /// nothing. Now a failure snaps the toggle back and says why, because a
    /// setting that silently doesn't apply is worse than one that refuses.
    private func applyLaunchAtLogin() {
        guard !applyingLaunchAtLogin else { return }   // re-entry from the revert below
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = Bundle.main.bundleIdentifier == nil
                ? "Launch at login needs the packaged app (make app)."
                : error.localizedDescription
            applyingLaunchAtLogin = true
            launchAtLogin = !launchAtLogin
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            applyingLaunchAtLogin = false
        }
    }

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let secs = self.refreshInterval
                try? await Task.sleep(for: .seconds(max(1, secs)))
            }
        }
    }
}
