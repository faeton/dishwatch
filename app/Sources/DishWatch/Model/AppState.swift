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
            self.isLive = !(provider is SampleProvider)
        } else if HelperProvider.locateHelper() != nil {
            // Preferred: the embedded, supervised helper. The only path that
            // works in a sandboxed bundle, and the one the Store build ships.
            self.provider = HelperProvider()
            self.isLive = true
        } else {
            // Release builds stop here: a shipped bundle always contains its
            // helper (app/Makefile fails the build otherwise), so reaching this
            // branch means something is wrong and the honest thing is to say so
            // rather than quietly substitute a fabricated dashboard.
            //
            // LiveProvider and SampleProvider are development-only. The former
            // is the legacy spawn-per-poll bridge that cannot work sandboxed;
            // the latter animates the design mock-up convincingly enough that
            // it must never be reachable in a build a user could install.
            #if DEBUG
            if LiveProvider.locateBinary() != nil {
                self.provider = LiveProvider()
                self.isLive = true
            } else {
                self.provider = SampleProvider()
                self.isLive = false
            }
            #else
            self.provider = MissingHelperProvider()
            self.isLive = false
            #endif
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

    func refresh() async { await refresh(generation: nil) }

    private func refresh(generation: Int?) async {
        do {
            var d = try await provider.poll()
            // Drop a result from a superseded poll loop rather than letting it
            // overwrite whatever the current one has already published.
            if let generation, generation != pollGeneration { return }
            if simulateBattery { d.onBattery = true; d.bankAnchored = true }
            // Only publish a genuine change. An unconditional assignment fires
            // objectWillChange every tick regardless, which re-renders the whole
            // popover tree and the menu-bar glyph for nothing.
            if d != data { data = d }
            lastError = nil
            lastGoodAt = Date()
            // A poll can succeed while something behind it failed — the dish
            // answered but the accumulators could not be written, say. That is
            // not an error, but it must not be silent either: the energy and
            // Observed figures on screen are then older than everything beside
            // them.
            warning = (provider as? HelperProvider)?.lastWarning
        } catch {
            if let generation, generation != pollGeneration { return }
            // Keep the last good snapshot but mark it offline + stale. The
            // numbers stay on screen because a frozen reading is more useful
            // than a blank one — provided the UI says it is frozen, which is
            // what `quality` below exists to make unambiguous.
            var d = data
            d.state = .offline
            if d != data { data = d }
            lastError = error.localizedDescription
        }
        if !hasLoaded { hasLoaded = true }
    }

    /// When the last successful poll landed, for the staleness readout.
    @Published private(set) var lastGoodAt: Date?
    /// Non-fatal problem reported alongside a good poll.
    @Published private(set) var warning: String?

    /// How much the numbers on screen can be trusted right now.
    ///
    /// This exists because "live" used to mean nothing more than "the transport
    /// call returned". The helper deliberately converts an unreachable dish into
    /// a *successful* poll carrying an Offline dashboard, so a reviewer with no
    /// dish saw a hero reading **Offline** directly above a footer reading
    /// **live**, over metrics restored from a persisted snapshot of arbitrary
    /// age. Transport success and link state are two different questions and
    /// the UI has to answer both.
    enum Quality {
        case loading         // no poll has completed yet
        case live            // fresh poll, dish reachable and reporting
        case disabled        // fresh poll, dish present but service disabled
        case offline         // fresh poll, nothing answering at the address
        case stale(String)   // poll failed; showing the last good snapshot
        case sample          // fabricated data, development builds only
        case brokenInstall(String)  // the helper is missing or unusable

        /// Whether the numbers on screen are current. `disabled` counts: the
        /// dish answered and told us it is disabled, which is a real reading.
        var isTrustworthy: Bool {
            switch self {
            case .live, .disabled: return true
            default:               return false
            }
        }
    }

    var quality: Quality {
        // A release build with no helper is a broken install, not a demo. This
        // used to fall through to `.sample`, which labelled a packaging failure
        // "sample data — not a real dish" and told the user nothing actionable.
        if provider is MissingHelperProvider {
            return .brokenInstall(lastError ?? "the app bundle looks incomplete")
        }
        if !isLive { return .sample }
        if let e = lastError { return .stale(e) }
        if !hasLoaded { return .loading }
        switch data.state {
        // `.weak` is a *connected* dish with a poor link — searching, booting,
        // obstructed. Collapsing it into "no dish at this address" was worse
        // than the bug this enum replaced: it took a live, correct reading and
        // captioned it as an absent dish. `swiftState` maps every non-connected,
        // non-disabled dish state to Weak, so this is the common case whenever
        // the link is anything but perfect.
        case .connected, .weak: return .live
        case .disabled:         return .disabled
        case .offline:          return .offline
        }
    }

    /// "12s ago" for the staleness readout, or nil when there is nothing to age.
    var lastGoodAgoText: String? {
        guard let t = lastGoodAt else { return nil }
        let s = Int(Date().timeIntervalSince(t))
        if s < 2 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    /// Result of a user-initiated command, surfaced in the UI until dismissed
    /// or superseded. `lastError` is unsuitable: the next successful poll
    /// clears it, so a failed reboot used to vanish within a second.
    @Published var actionResult: String?

    /// Reboot the dish. Triggers an immediate poll afterwards so the UI
    /// reflects the drop.
    ///
    /// The failure path used to be unreachable. `HelperProvider.reboot` swallowed
    /// its own error with `try?`, so this `catch` never ran and a reboot that
    /// did not happen was indistinguishable from one that did — after the user
    /// had confirmed a destructive action. Both halves are fixed: the provider
    /// throws, and the outcome is reported somewhere that outlives one poll.
    func reboot() async {
        guard let h = provider as? HelperProvider else {
            actionResult = "Reboot needs a live dish connection."
            return
        }
        do {
            try await h.reboot()
            actionResult = "Reboot sent. The dish will drop for 1–2 minutes."
        } catch {
            actionResult = "Reboot failed: \(error.localizedDescription)"
        }
        await refresh()
    }

    /// Anchor the power bank. Maps to `sl pb <pct> [wh]`.
    ///
    /// Nothing called the provider's setAnchor at all — the battery sheet's
    /// buttons were inert — so this is the wire that was missing.
    func setBankAnchor(pct: Double, wh: Double?) async {
        guard let h = provider as? HelperProvider else {
            actionResult = "Battery tracking needs a live dish connection."
            return
        }
        do {
            try await h.setAnchor(pct: pct, wh: wh)
            actionResult = wh.map { "Bank anchored at \(Int(pct))% · \(Int($0)) Wh" }
                ?? "Bank anchored at \(Int(pct))%"
        } catch {
            actionResult = "Could not set the anchor: \(error.localizedDescription)"
        }
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

    /// Bumped on every restart. `cancel()` does not stop an in-flight
    /// `provider.poll()`, so without a generation tag the old loop's result
    /// could land *after* the new loop's and overwrite fresher data with older
    /// — silently, since both writes are on the main actor and neither errors.
    /// Changing the refresh interval a few times was enough to trigger it.
    private var pollGeneration = 0

    private func restartPolling() {
        pollTask?.cancel()
        pollGeneration &+= 1
        let generation = pollGeneration
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard self.pollGeneration == generation else { return }
                await self.refresh(generation: generation)
                let secs = self.refreshInterval
                try? await Task.sleep(for: .seconds(max(1, secs)))
            }
        }
    }
}
