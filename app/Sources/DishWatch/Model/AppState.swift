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
    /// Which values the status item appends after its glyph. Rendered in
    /// `MenuBarField.allCases` order, not tick order, so the bar layout is
    /// stable. Stored as raw strings: an unknown one from a newer build is
    /// dropped on read rather than failing the whole setting.
    @Published var menuBarFields: Set<MenuBarField> {
        didSet { defaults.set(menuBarFields.map(\.rawValue), forKey: Self.fieldsKey) }
    }
    /// Seconds of sparkline history to request — 60, 300 or 900, bounded by the
    /// depth of the dish's own ring. Changing it re-polls at once: the series
    /// arrive with the snapshot, so without this the new window would not appear
    /// until the next tick, which at a 60 s refresh interval is a long time to
    /// watch a control that looks broken.
    @Published var historyWindow: Int {
        didSet {
            defaults.set(historyWindow, forKey: "historyWindow")
            // `restartPolling`, not a bare `Task { await refresh() }`.
            //
            // The series arrive with the snapshot, so the new window has to be
            // fetched at once or the control looks broken until the next tick —
            // but the plain `refresh()` passes `generation: nil`, which is
            // exempt from the supersession check by design (it is what the
            // manual "Refresh now" uses). Two quick window changes could then
            // publish in completion order rather than request order and leave
            // the picker on 15m above a 5m snapshot. Restarting the loop bumps
            // the generation, so a superseded reply is dropped, and it polls
            // immediately — which is exactly what `refreshInterval` does.
            if historyWindow != oldValue { restartPolling() }
        }
    }
    @Published var pinnedWidget: Bool {
        didSet { defaults.set(pinnedWidget, forKey: "pinned"); pinnedController.setVisible(pinnedWidget) }
    }
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin"); applyLaunchAtLogin() }
    }
    @Published var refreshInterval: Int {
        didSet { defaults.set(refreshInterval, forKey: "refresh"); restartPolling() }
    }
    /// Draw the ↓↑ figures in their popover hues rather than in the bar's ink.
    ///
    /// Off by default, and the default is not timidity — it is the only setting
    /// with a real cost. A coloured status item cannot be a *template* image,
    /// and a template image is what makes the glyph tint itself white on a dark
    /// bar and black on a light one, for free, including appearances Apple has
    /// not shipped yet. Turning this on hands that job to us: every other part
    /// of the readout then has to be inked by hand per appearance, from a
    /// colour scheme we sample ourselves. It looks good and it is worth
    /// offering; it is not what a fresh install should silently opt into.
    @Published var colorThroughput: Bool {
        didSet { defaults.set(colorThroughput, forKey: "colorThroughput") }
    }
    /// Demo-only: force the popover into battery layout regardless of real power.
    @Published var simulateBattery: Bool {
        didSet { Task { await refresh() } }
    }
    /// Why the last launch-at-login change didn't take, if it didn't.
    @Published private(set) var launchAtLoginError: String?
    private var applyingLaunchAtLogin = false

    private let provider: DishProvider
    /// Injectable so tests can exercise the settings migration against a
    /// scratch suite instead of the developer's real preferences — the
    /// migration only runs on a domain that has the *old* keys and not the new
    /// one, which is a state `UserDefaults.standard` is in exactly once.
    private let defaults: UserDefaults
    private var pollTask: Task<Void, Never>?
    private lazy var pinnedController = PinnedPanelController(store: self)

    /// Live (real dish) by default when the `dishwatch` binary is found; falls
    /// back to sample data otherwise so the app still runs.
    let isLive: Bool

    init(provider: DishProvider? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        let bar = Self.loadMenuBar(defaults)
        self.iconMode = bar.icon
        self.menuBarFields = bar.fields
        self.historyWindow = defaults.object(forKey: "historyWindow") as? Int ?? 60
        self.pinnedWidget = defaults.object(forKey: "pinned") as? Bool ?? false
        self.launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
        self.refreshInterval = defaults.object(forKey: "refresh") as? Int ?? 1
        self.colorThroughput = defaults.object(forKey: "colorThroughput") as? Bool ?? false
        self.simulateBattery = false
        restartPolling()
        pinnedController.setVisible(pinnedWidget)
    }

    deinit { pollTask?.cancel(); egressTask?.cancel() }

    // MARK: - menu-bar settings

    private static let fieldsKey = "menuBarFields"
    /// The `IconMode` raw value retired when numbers became `MenuBarField`s.
    private static let retiredDataReadout = "Data readout"

    /// What a fresh install starts with. Throughput first because that is what
    /// the bar is for; ping because it is the number that tells you whether the
    /// link is usable rather than merely up; battery because it costs nothing —
    /// it renders only once an anchor is set.
    static let defaultFields: Set<MenuBarField> = [.ping, .down, .up, .battery]

    /// Offered sparkline windows, in seconds. Capped by the depth of the dish's
    /// `dishGetHistory` ring (900 samples, one per second) — see
    /// `maxSeriesWindow` in dashboard.go. Offering more would show a 15-minute
    /// trace under a longer caption.
    static let historyWindows = [60, 300, 900]

    /// Resolve the stored glyph + fields, migrating pre-field preferences.
    ///
    /// The distinction that matters here is upgrade versus fresh install. An
    /// upgrading user gets exactly what they were already looking at — anything
    /// else silently redecorates a menu bar they had configured. Only a genuinely
    /// new install gets `defaultFields`, and "genuinely new" means no icon
    /// preference was ever written.
    private static func loadMenuBar(_ defaults: UserDefaults) -> (icon: IconMode, fields: Set<MenuBarField>) {
        let storedIcon = defaults.string(forKey: "iconMode")

        if let raw = defaults.array(forKey: fieldsKey) as? [String] {
            let icon = IconMode(rawValue: storedIcon ?? "") ?? .signalBars
            return (icon, Set(raw.compactMap(MenuBarField.init(rawValue:))))
        }

        // No field list yet: either a first launch, or a build that predates it.
        //
        // "Predates it" is not the same as "has an iconMode". Both legacy keys
        // were written only by their own `didSet`, so a user who turned *Show
        // value* off and never touched the glyph picker has `showValue` and no
        // `iconMode` — a real and unremarkable state, and one that read as a
        // fresh install here. That silently replaced their bare glyph with the
        // four-field default: the one outcome this whole function exists to
        // prevent. An upgrade is any domain carrying *either* legacy key.
        let legacyShowValue = defaults.object(forKey: "showValue") as? Bool
        guard storedIcon != nil || legacyShowValue != nil else {
            // Persisted, not just returned. `init` assigns these properties, and
            // Swift does not run `didSet` during initialisation, so a fresh
            // install that only *returned* here wrote nothing — and the first
            // tap on the glyph picker (`iconMode.didSet`, which writes only
            // `iconMode`) then produced `{iconMode, no fields, no showValue}`.
            // On the next launch that is indistinguishable from a pre-fields
            // upgrade, so the branch below would read the absent `showValue` as
            // its old default of `true` and quietly collapse the four-field
            // default to the signal score alone. Writing the resolved pair now
            // means the upgrade branch is only ever reached by a domain that
            // genuinely predates fields.
            let fresh: (IconMode, Set<MenuBarField>) = (.signalBars, defaultFields)
            persist(fresh, to: defaults)
            return fresh
        }

        if storedIcon == retiredDataReadout {
            // The mode drew "31ms" *instead of* a glyph, so it maps to exactly
            // that and not to a glyph with a number bolted on.
            let migrated: (IconMode, Set<MenuBarField>) = (.noGlyph, [.ping])
            persist(migrated, to: defaults)
            return migrated
        }
        // No stored glyph means the user never moved off the old default.
        let icon = storedIcon.flatMap(IconMode.init(rawValue:)) ?? .signalBars
        // `showValue` appended the signal score in every surviving mode; off
        // meant a bare glyph. Both are representable exactly. Its own default
        // was on, which is what an absent key means here.
        let migrated: (IconMode, Set<MenuBarField>) = (icon, (legacyShowValue ?? true) ? [.signal] : [])
        persist(migrated, to: defaults)
        return migrated
    }

    private static func persist(_ v: (icon: IconMode, fields: Set<MenuBarField>), to defaults: UserDefaults) {
        defaults.set(v.icon.rawValue, forKey: "iconMode")
        defaults.set(v.fields.map(\.rawValue), forKey: fieldsKey)
    }

    /// One rendered field. A struct rather than a tuple because `ForEach` needs
    /// an `Identifiable` element, and Swift has no key paths into tuples.
    struct MenuBarItem: Identifiable {
        let field: MenuBarField
        let text: String
        var id: MenuBarField { field }
    }

    /// The fields to draw, in render order, each with its current text. The
    /// sparkline is not here — it is not text — and a field with nothing to say
    /// right now (battery off a bank) drops out rather than rendering a zero.
    var menuBarTexts: [MenuBarItem] {
        let live = quality.showsLiveReadings
        return MenuBarField.allCases.compactMap { f in
            guard menuBarFields.contains(f), let t = f.text(data, live: live) else { return nil }
            return MenuBarItem(field: f, text: t)
        }
    }

    /// Whether the bar should draw the ping sparkline.
    var showsMenuBarSpark: Bool { menuBarFields.contains(.pingSpark) }

    /// The trace the bar plots — empty when there is no live reading behind it,
    /// which `MenuBarSpark` draws as a dashed midline rather than as a frozen
    /// shape that keeps implying a link.
    ///
    /// Emptied rather than hidden: the status item must never shrink to zero
    /// width, or there is nothing left to click to undo the setting.
    var menuBarSparkValues: [Double] {
        quality.showsLiveReadings ? data.pingSeries : []
    }

    /// How full the bar's signal glyph draws. Zero without a live reading —
    /// on a failed poll the last snapshot's score is still in `data`, so the
    /// glyph kept four lit bars over a dead link.
    var menuBarSignalFraction: Double {
        quality.showsLiveReadings ? Double(data.signalScore) / 100 : 0
    }

    /// Everything the status item renders as text, joined — one string is all
    /// the glyph cache needs to compare, and all the tooltip needs to quote.
    var menuBarText: String { menuBarTexts.map(\.text).joined(separator: " ") }

    /// One poll: fetch, apply demo override, keep last-good on failure.
    /// For the headless render path only: present a snapshot as if it had been
    /// polled. Takes the data so the harness can pose cases the sample provider
    /// cannot reach — an idle link, say, which is where the menu bar's
    /// throughput formatting is worth looking at and where the sample's
    /// 142.5 Mbps says nothing.
    func seed(_ d: DishData = .sample) { data = d; hasLoaded = true }

    func refresh() async { await refresh(generation: nil) }

    private func refresh(generation: Int?) async {
        do {
            var d = try await provider.poll(window: historyWindow)
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
            // The footer shows one line of this; the log keeps the rest. An
            // unreachable dish arrives here as an ordinary, expected failure,
            // but so does a decode error from a firmware change, and on screen
            // those two look identical.
            EngineLog.failure("poll", error)
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

        /// Whether the menu bar may quote link readings as current.
        ///
        /// Not `isTrustworthy`, and the difference is `.sample`: fabricated data
        /// is wrong about the world but is internally current, and the render
        /// harness and the design demo exist to look at it. Everything else that
        /// is not trustworthy has the same problem in the bar — a number with no
        /// live reading behind it — including `.loading`, where the alternative
        /// is a first frame of `0ms ↓0.0 ↑0.0`.
        ///
        /// The popover does not need this: it dims and desaturates the whole
        /// panel and says why in its footer. The bar is a template image with
        /// no room for either, so its numbers have to carry it themselves.
        var showsLiveReadings: Bool {
            switch self {
            case .live, .disabled, .sample: return true
            case .loading, .offline, .stale, .brokenInstall: return false
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
            EngineLog.failure("reboot", error)
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
            EngineLog.failure("setAnchor", error)
        }
        await refresh()
    }

    // MARK: - Exit address

    /// What the panel knows about where this Mac's traffic leaves.
    ///
    /// `untried` is a first-class case rather than a `nil` `Egress`, because
    /// "we have not asked anyone" and "we asked and got nothing" have to look
    /// different on screen. The first is the resting state of a feature that
    /// deliberately does nothing until invited; the second is a failure.
    enum EgressState: Equatable {
        case untried
        case checking
        case ok(Egress, at: Date)
        case failed(String)
    }

    /// In memory only. Never written to `UserDefaults`: the reading contains a
    /// public IP address, and an app that keeps one on disk has to say so in a
    /// privacy label. It costs one request to get it back.
    @Published private(set) var egress: EgressState = .untried
    private var egressTask: Task<Void, Never>?

    /// Ask where this Mac's traffic leaves.
    ///
    /// **Every call is a press.** There is no timed path, no panel-open path
    /// and no cache to serve a stale answer from: the only callers are the
    /// Check and refresh buttons, so a request goes out exactly when a user
    /// asks for one and never otherwise. That is also why a fresh answer is
    /// not reused — the reason to press it a second time is that you just
    /// changed networks, which is precisely when the cached reading is wrong.
    ///
    /// Not `async`: the call site is a button action and wants to return
    /// immediately with the row showing `checking`.
    func checkEgress() {
        // The one thing a second press must not do is open a second request.
        if case .checking = egress { return }
        egressTask?.cancel()
        egress = .checking
        let url = EgressLookup.endpoint(defaults)
        egressTask = Task { [weak self] in
            do {
                let e = try await EgressLookup.fetch(from: url)
                guard let self, !Task.isCancelled else { return }
                self.egress = .ok(e, at: Date())
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.egress = .failed(EgressLookup.message(for: error))
                EngineLog.failure("egress", error)
            }
        }
    }

    /// The host the check will contact, for the disclosure line. Read from the
    /// same place the request is, so the sentence on screen cannot name one
    /// server while the app calls another.
    var egressHost: String { EgressLookup.displayHost(EgressLookup.endpoint(defaults)) }

    /// For the headless render path only — see `seed`. Poses a reading the
    /// harness could not otherwise reach without a network.
    func seed(egress: EgressState) { self.egress = egress }

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
