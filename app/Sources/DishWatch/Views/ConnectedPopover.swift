import SwiftUI

/// Screen A — connected, on mains. Gauge + metric grid + sparklines + detail.
struct ConnectedPopover: View {
    var d: DishData
    @Binding var showSettings: Bool
    /// Injectable so the render harness can draw a channel this process is not.
    /// `BuildInfo.main` reads `Bundle.main`, and the harness runs as a bare
    /// SwiftPM executable with no Info.plist — so left to itself every snapshot
    /// would show the one case that draws nothing.
    var build: BuildInfo = .main
    @EnvironmentObject var store: AppState
    @State private var detailExpanded: Bool
    @State private var confirmReboot = false
    /// Non-nil only while a drag is on one of the sparklines.
    @State private var scrub: Scrub?

    /// `startExpanded` exists for the render harness, and it closes a real gap
    /// rather than adding a knob. Everything in the detail row — the bearing,
    /// the country's disclaimer, the service caveat, and now the exit reading
    /// with its four states — sits behind `@State` that no snapshot could ever
    /// reach, so the one part of the panel made entirely of wrapping paragraphs
    /// was the one part never checked for wrapping. Same reason `ConfirmStrip`
    /// is a separate view.
    init(d: DishData, showSettings: Binding<Bool>, build: BuildInfo = .main,
         startExpanded: Bool = false) {
        self.d = d
        self._showSettings = showSettings
        self.build = build
        self._detailExpanded = State(initialValue: startExpanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                hero
                Divider().background(DW.hairline).padding(.horizontal, 16)
                metricGrid.padding(.top, 14).padding(.horizontal, 16)
                sparklines.padding(.top, 4)
                observedFooter
                detailRow.padding(.horizontal, 16).padding(.top, 6)
            }
            // Frozen numbers should look frozen. On a failed poll the previous
            // snapshot stays on screen at full fidelity, which is useful — but
            // only if it is visibly not current. The footer's small "stale" text
            // was carrying that entire message on its own.
            .opacity(store.quality.isTrustworthy ? 1 : 0.5)
            .saturation(store.quality.isTrustworthy ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: store.quality.isTrustworthy)

            rebootConfirm
            actionBanner
            footer
        }
        .foregroundStyle(DW.text)
        .overlay(TopGlow(color: DW.cyan), alignment: .top)
        .animation(.easeOut(duration: 0.16), value: confirmReboot)
    }

    /// The reboot confirmation, as panel content rather than a modal.
    ///
    /// It was a `.confirmationDialog`, and a `.confirmationDialog` cannot work
    /// here. `MenuBarExtra(.window)` is a non-activating panel; the dialog is a
    /// separate AppKit-owned window that has to become key before its buttons
    /// can take a press, and it never does. The click lands as *panel resigns
    /// key*, the panel closes, and because dismissal already is the cancel
    /// outcome, Cancel looked like it worked while Reboot — the one button
    /// whose success would have been visible — could never fire. The app's only
    /// destructive action was inert, and reported by a user as "just closes
    /// window".
    ///
    /// PopoverView records exactly this rule for `.sheet`, and the battery
    /// setup screen was converted to panel content because of it. This was the
    /// last modal in the app that had not been.
    @ViewBuilder private var rebootConfirm: some View {
        if confirmReboot {
            ConfirmStrip(
                title: "Reboot the dish?",
                message: "The connection will drop for ~1–2 minutes.",
                confirmTitle: "Reboot",
                onCancel: { confirmReboot = false },
                onConfirm: {
                    confirmReboot = false
                    Task { await store.reboot() }
                })
            .padding(.horizontal, 16).padding(.top, 10)
            // Outside the block that dims on a stale poll, like the action
            // banner below it. A control the user is mid-way through answering
            // must not fade out because a poll timed out underneath them.
            .transition(.opacity)
        }
    }

    /// Outcome of the last command. Lives outside `lastError` because that is
    /// cleared by the next successful poll, which meant a failed reboot was
    /// visible for well under a second — after the user had confirmed a
    /// destructive action and was owed an answer.
    @ViewBuilder private var actionBanner: some View {
        // A poll can succeed while the accumulators failed to persist. The dish
        // numbers are current; the Energy and Observed figures beside them are
        // not. The helper reports it, AppState stores it, and until now nothing
        // rendered it — which made a full or read-only container silent.
        if let w = store.warning {
            Text(w)
                .font(.system(size: 11))
                .foregroundStyle(DW.amber.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 8)
        }
        if let msg = store.actionResult {
            HStack(spacing: 8) {
                Text(msg)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DW.text.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    store.actionResult = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DW.textA(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    /// Title row: brand, clock, gear.
    ///
    /// The hardware chip was here for one release and did not fit. The run
    /// between the app name and the clock measures ~145 pt and the chip needs
    /// ~185 for a real dish, so it shipped as `Standard… · Self-a…` — the two
    /// halves of the one fact it exists to state, both cut. It looked fine only
    /// against `DishData.sample`, whose `Mini` and `mini1_panda` are shorter
    /// than anything a real dish reports; see the `connected-long` harness case,
    /// which exists so this cannot pass a screenshot again.
    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                SignalBars(color: DW.cyan, height: 13, barWidth: 3, fraction: Double(d.signalScore) / 100)
                Text("DishWatch").font(.system(size: 14, weight: .bold))
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Text(Date.now, format: .dateTime.hour().minute().second())
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(DW.textA(0.5))
                AppMenuButton(showSettings: $showSettings,
                              refresh: { Task { await store.refresh() } },
                              reboot: { confirmReboot = true })
            }
        }
        .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 10)
    }

    private var hero: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    StatusDot(color: dotColor, pulse: store.hasLoaded && d.state == .connected)
                    Text(heroLabel).font(.system(size: 22, weight: .bold))
                }
                // Why, immediately under the what. "Disabled" on its own is the
                // panel's least useful word: it is the one state the owner can
                // sometimes act on, and the action depends entirely on a cause
                // the hero cannot hold — sailing back inshore and paying a bill
                // are both answers to it.
                //
                // Wraps rather than truncates. The longest cause is a clause,
                // not a word, and half of "over open ocean, which this plan does
                // not cover" is worse than none of it.
                if let why = d.serviceBlockedReason {
                    Text(why)
                        .font(.system(size: 12))
                        // Red to match the dot beside it, not amber: amber is
                        // the theme's power colour and `.disabled` already
                        // draws a red dot. A cause in a third colour would read
                        // as a third severity.
                        .foregroundStyle(DW.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                // Identity first, then the session facts. The model used to
                // trail the uptime line as a bare word, then spent a release in
                // the header where it did not fit; here it has the panel's full
                // left column — ~270 pt against the ~185 the longest real chip
                // needs — so both halves survive, including the one the bare
                // word never carried: whether the panel aims itself.
                // Gated here, not only inside the chip: the chip draws nothing
                // without a model, but this padding would still be padding, and
                // an unknown or offline dish would get a blank band where the
                // chip should be.
                if HardwareChip.hasModel(d.hardwareShort) {
                    HardwareChip(model: d.hardwareShort, aim: d.hardwareAim)
                        .padding(.top, 9)
                }
                // Session facts, and where the dish thinks it is sitting while
                // it has them. The country shares this line rather than taking
                // one of its own because it is the same kind of reading as the
                // two beside it — small, current, and true only of this boot —
                // and because the identity lines below are strings you copy,
                // not ones you glance at.
                //
                // Baseline-aligned, not centre-aligned: the flag is a colour
                // emoji with its own metrics, and centring would float it a
                // point above the digits it sits next to.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("up \(Self.uptime(d.uptimeSeconds)) · boots \(d.boots)")
                        .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(DW.textA(0.55))
                    // Silent unless the dish named a country — see
                    // `countryBadge`. An offline snapshot has none, and this is
                    // not a fact worth inventing from coordinates the panel
                    // never asks for.
                    if let badge = d.countryBadge {
                        // No `.help` here. The explanation lives in the detail
                        // row, where it can actually be read — a tooltip in a
                        // non-activating panel is a fact nobody receives.
                        Text("· \(badge)")
                            .font(.system(size: 12.5)).foregroundStyle(DW.textA(0.55))
                    }
                }
                .padding(.top, 8)
                // Two lines, both whole. A real dish reports a 28-character ID
                // and a 20-character firmware string, and `%@ · fw %@` cannot
                // hold them: it truncated to `…-00ed07ca · fw 2026.0…`, cutting
                // the half that changes between releases. Eliding the ID's
                // middle to save the line was the previous fix and this is a
                // better one — nothing is abbreviated, and the panel has the
                // vertical room it did not have horizontally.
                Text(d.deviceId)
                    .font(.system(size: 11.5)).foregroundStyle(DW.textA(0.38))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    // Width-only, as on the spark trailing — see the note
                    // there. Vertical pressure must not buy font size.
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 3)
                Text("fw \(d.firmware)")
                    .font(.system(size: 11.5)).foregroundStyle(DW.textA(0.38))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    // Width-only, as on the spark trailing — see the note
                    // there. Vertical pressure must not buy font size.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
                // What the dish is provisioned for — a static fact about this
                // unit, so it belongs with the ID and the firmware rather than
                // in the metric grid, which is for readings.
                //
                // A step brighter than the two lines above it: those are
                // strings you copy when filing a support ticket, this is one
                // you read. It is also the answer to a question people ask of
                // this panel ("what plan is this dish on?") and the ID is not.
                //
                // Nothing renders when the dish did not say, which includes a
                // stationary dish reporting no mobility at all — see
                // `serviceLine`. That is why it is not gated with the chip
                // above: the two go quiet under different conditions.
                if let service = d.serviceLine {
                    Text(service)
                        .font(.system(size: 11.5)).foregroundStyle(DW.textA(0.5))
                        .lineLimit(1).minimumScaleFactor(0.8)
                    // Width-only, as on the spark trailing — see the note
                    // there. Vertical pressure must not buy font size.
                    .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                }
            }
            Spacer()
            SignalGauge(score: d.signalScore, size: 78)
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 16)
        .background(alignment: .leading) { dishBackdrop }
        // The backdrop bleeds past the leading edge by design; without this it
        // would also bleed into the divider and the metric grid below.
        .clipped()
    }

    /// The dish itself, drawn large and faint behind the status block.
    ///
    /// Decoration, and the honest kind: it is the same outline the chip carries
    /// at 15 pt, so it says exactly what the chip says and nothing more. Every
    /// current model is a flat panel on a stem, differing in size rather than
    /// shape, so one silhouette is a true picture of whichever one is out
    /// there — the words beside it are what name the generation.
    ///
    /// Gated on there being a model at all, which is the same condition the chip
    /// draws under. An offline snapshot with no reading has no dish to depict,
    /// and a decorative one would be the only thing on a dimmed panel still
    /// claiming to know something.
    ///
    /// 7% opacity, no glow: it has to survive being read *through*, and the
    /// identity lines sitting on it are already the dimmest text on the panel.
    @ViewBuilder private var dishBackdrop: some View {
        if HardwareChip.hasModel(d.hardwareShort) {
            DishGlyph(size: 170, glow: false)
                .opacity(0.11)
                .offset(x: -26, y: -4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var metricGrid: some View {
        Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            GridRow {
                MetricCell(label: "Download", value: String(format: "%.1f", d.downMbps), unit: "Mbps",
                           barFrac: d.downBarFrac, barColor: DW.down)
                // Violet, matching the ↑ trace and legend below. The cell drew
                // its bar in the *download* blue, which was invisible while the
                // two colours only ever appeared in separate cells and is a
                // miscue now that one chart distinguishes the directions by
                // colour alone.
                MetricCell(label: "Upload", value: String(format: "%.1f", d.upMbps), unit: "Mbps",
                           barFrac: d.upBarFrac, barColor: DW.up)
            }
            GridRow {
                MetricCell(label: "Ping", value: "\(Int(d.pingMs))", unit: "ms",
                           sub: "drop \(String(format: "%.1f", d.dropPct))% · \(d.noiseOK ? "noise ✓" : "noise ✗")")
                MetricCell(label: "Power", value: String(format: "%.1f", d.powerW), unit: "W",
                           sub: powerSub)
            }
        }
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The Power cell's sub-label: the session peak, not an energy total.
    ///
    /// Energy lived here for two releases and did not belong. The cell is where
    /// you look for *watts now*, it is half a popover wide — the honest
    /// three-case energy string overflowed it and shipped truncated as
    /// `115.1 Wh over 3h 44m · 30....` — and once the Observed block grew its
    /// own energy figure the two sat a few points apart showing near-identical
    /// numbers over subtly different windows. No amount of tooltip fixes that;
    /// the second number was the problem.
    ///
    /// The peak is a fact nothing else on screen shows. Without an Observed
    /// block there is no peak to show, so the cell falls back to a *short* energy
    /// string — short because this fallback is not the cold start it was assumed
    /// to be. Stats can be unready while `state.json` still holds a long energy
    /// epoch: a `StatsVersion` bump, a missing or corrupt `stats.json`, a helper
    /// that bootstraps stats late. Returning the full three-case `energyLine`
    /// here would let `115.1 Wh over 3h 44m · 30....` back onto the screen for as
    /// long as that lasts, which is the truncation v0.2.4 removed.
    private var powerSub: String {
        if let o = d.observed { return "peak \(String(format: "%.1f", o.powerPeak)) W" }
        return "\(Self.wh(d.energyWhSinceBoot)) measured"
    }

    /// The energy total, said only as strongly as the samples allow.
    ///
    /// Three cases, matching `renderEnergy` in dash.go so the CLI and the app
    /// cannot describe one accumulator differently. This used to be the single
    /// string `"%.1f Wh since boot"`, which is the strongest of the three and
    /// true only in the first: the accumulator integrates samples it actually
    /// retrieved, so after any gap it holds an under-count. Measured here, a
    /// dish that had drawn roughly 900 Wh displayed `90.3 Wh since boot`.
    private var energyLine: String {
        let wh = String(format: "%.1f", d.energyWhSinceBoot)
        if d.energyCoversBoot {
            return "\(wh) Wh since boot"
        }
        if d.energyAvgW > 0, d.energySeconds > 0 {
            // Name the window the figure covers instead of the boot it doesn't.
            return "\(wh) Wh over \(Self.span(Int(d.energySeconds))) · \(String(format: "%.1f", d.energyAvgW)) W"
        }
        // No honest denominator: quote the total and claim nothing about it.
        return "\(wh) Wh measured"
    }


    /// Test seam for `energyLine`, which is private and not a `View`.
    var energyLineForTesting: String { energyLine }
    var powerSubForTesting: String { powerSub }
    func energyHelpForTesting(_ o: ObservedStats) -> String { energyHelp(o) }

    private var sparklines: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                // The window the *data* covers, not the one that was requested.
                // A dish two minutes past a reboot answers a 15-minute request
                // with two minutes of ring, and captioning that "15 m" would be
                // the same class of lie as the `max` figure this block already
                // lost once.
                SectionLabel(text: headingLabel).tracking(0.8)
                    .help("Covers the last \(Self.span(d.seriesSeconds)) the dish has in its own history ring — which is all of it after a reboot, however wide a window you pick.")
                Spacer()
                windowPicker
            }
            ForEach(SparkRow.allCases) { row in
                sparkRow(row)
            }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
        // A gesture that never ends leaves a marker behind: `onEnded` does not
        // fire when the panel is dismissed mid-drag, and this block outlives a
        // dismissal.
        .onDisappear { scrub = nil }
    }

    /// The sparkline rows.
    ///
    /// Download and upload are **one row with two traces**, not two rows. They
    /// share a unit and a window, so one shared axis is both drawable and
    /// honest, and it makes the thing people actually read a chart of
    /// throughput for — the gap between the two directions — a distance on
    /// screen rather than a comparison between two independently auto-ranged
    /// pictures.
    ///
    /// An enum rather than three calls to a generic row helper: the scrub state
    /// has to name a row, and a label string is a poor key for one.
    private enum SparkRow: String, CaseIterable, Identifiable {
        case ping, throughput, power
        var id: String { rawValue }
    }

    /// Where a drag currently is, for the one row being scrubbed.
    ///
    /// One piece of state for all three rows rather than one each: only one
    /// pointer is ever down, and per-row state lets a released marker linger.
    private struct Scrub: Equatable {
        var row: SparkRow
        /// Column under the pointer — see `Spark.span`.
        var column: Int
    }

    /// Where each row's chart floor sits.
    ///
    /// Throughput is the one quantity here with a true zero, and the only row
    /// where amplitude is meant to mean magnitude. Auto-ranging it draws a
    /// rock-steady 140–143 Mbps link as a rollercoaster, and on a shared axis a
    /// download and upload that happen to sit close together become two
    /// full-height traces of noise — utilization drawn as amplitude, which is
    /// the `avg 3` defect in picture form.
    ///
    /// Ping and power keep auto-ranging, because for them the variation *is*
    /// the news: a 20–36 ms ping pinned to the bottom of a 0-based row says
    /// nothing at all.
    private func baseline(_ row: SparkRow) -> Spark.Baseline {
        row == .throughput ? .zero : .auto
    }

    /// The traces a row actually draws. Series the dish did not send are
    /// dropped here, so nothing downstream — the legend, the scrub readout, the
    /// age in the heading — can describe a line that is not on screen.
    private func drawn(_ row: SparkRow) -> [SparkTrace] {
        traces(row).filter { $0.values.count > 1 }
    }

    private func traces(_ row: SparkRow) -> [SparkTrace] {
        switch row {
        case .ping:
            return [SparkTrace(values: d.pingSeries, color: DW.cyan)]
        case .throughput:
            // Download keeps the gradient; upload is a line, a little thicker.
            // A low trace *inside* another trace's fill dissolves into it, which
            // is how a real 14 Mbps upload comes to read as no upload at all.
            // …and a heavier fill than a lone trace carries, because the pair
            // is only easy to read while one of them is an *area*. At the
            // shared row's usual shape — download an order up from upload — the
            // hues are enough. At the shape this dish actually spends its day
            // in, both directions a few Mbps and crossing constantly, they are
            // not, and the body under the download line is what tells them
            // apart without a legend lookup.
            //
            // The upload stroke went the other way: 1.7 pt of full-strength
            // violet was the heaviest ink in the block, so the quieter of the
            // two directions was drawing the loudest line. The fill under
            // download is what carries the pair now, which is exactly what it
            // was widened for — so the line above it does not also have to
            // shout.
            return [SparkTrace(symbol: "↓", values: d.downSeries, color: DW.down,
                               fillOpacity: 0.5),
                    SparkTrace(symbol: "↑", values: d.upSeries, color: DW.up.opacity(0.85),
                               filled: false, width: 1.5)]
        case .power:
            return [SparkTrace(values: d.powerSeries, color: DW.amber)]
        }
    }

    /// The heading names the span the *data* covers — and, while a row is being
    /// scrubbed, how far back the marked sample sits instead. The dish records
    /// one sample per second, so a column distance is an age, and this is the
    /// only place with room to say it.
    /// Derived on every frame from the row's *current* span rather than stored
    /// with the gesture. A poll landing mid-drag shifts the series left, and a
    /// stored age would then caption the marked sample as younger than it now
    /// is — the same class of stale caption `seriesSeconds` exists to prevent.
    private var headingLabel: String {
        guard let s = scrub else { return coveredLabel }
        let span = Spark.span(drawn(s.row))
        let ago = span - min(span, max(0, s.column))
        return ago == 0 ? "now" : "\(Self.span(ago)) ago"
    }

    /// An unreachable dish returns no ring at all, and "Last 0 s" over three
    /// empty traces states a measurement of zero duration. Name the absence.
    private var coveredLabel: String {
        d.seriesSeconds > 0 ? "Last \(Self.span(d.seriesSeconds))" : "No history yet"
    }

    /// A sparkline span. Distinct from `dur`, which the CLI shares and which
    /// rolls 60 s up into "1m" — right for an uptime figure, wrong on a button
    /// beside "5m" and "15m", where the shortest window has always been called
    /// 60 s and rounding it up makes three buttons read like a nonsense scale.
    static func span(_ seconds: Int) -> String {
        seconds < 120 ? "\(seconds)s" : dur(Int64(seconds))
    }

    /// 60 s / 5 m / 15 m over the dish's own history ring. The ceiling is that
    /// ring's depth — 900 samples at one per second — not a product decision, so
    /// there is no point offering a longer one.
    private var windowPicker: some View {
        HStack(spacing: 3) {
            ForEach(AppState.historyWindows, id: \.self) { secs in
                let on = store.historyWindow == secs
                Button {
                    store.historyWindow = secs
                } label: {
                    Text(Self.span(secs))
                        .font(.system(size: 10.5, weight: on ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(on ? Color(hex: 0x04121B) : DW.textA(0.55))
                        .padding(.horizontal, 7).padding(.vertical, 2.5)
                        .background(on ? DW.cyan : Color.white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show the last \(Self.span(secs))")
            }
        }
    }

    /// The Observed block — long-window link quality for the current dish boot.
    ///
    /// Absent entirely until now: `DishData.observed` was decoded strictly,
    /// covered by tests, and read by no view, so every honesty guarantee behind
    /// the word "Observed" was guarding something that never rendered.
    ///
    /// `observed == nil` hides the row. That is the whole cold-start rule —
    /// under 120 samples the CLI emits zeros across the block, and zeros here
    /// would be statistics nobody measured.
    @ViewBuilder private var observedFooter: some View {
        if let o = d.observed {
            VStack(alignment: .leading, spacing: 5) {
                SectionLabel(text: "Observed \(Self.dur(o.seconds))").tracking(0.8)
                Text(observedLine(o))
                    .font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(DW.textA(0.7))
                if o.outages > 0 {
                    Text("\(o.outages) outage\(o.outages == 1 ? "" : "s") · \(Self.dur(o.outageSeconds)) dark · longest \(Self.dur(o.longestOutage))")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(DW.amber.opacity(0.85))
                }
                // Split into two views so the energy figure can carry its own
                // tooltip. A `Text` concatenation takes one `.help` for the
                // whole run, and the question people actually ask here is about
                // this number specifically: *used over how long?*
                //
                // Energy sits with the other session totals, not with the live
                // Power cell: it is a total for this block's window, computed
                // from this block's own samples.
                HStack(spacing: 0) {
                    Text("\(Self.bytes(o.downBytes)) ↓ · \(Self.bytes(o.upBytes)) ↑")
                        .help("Transferred during the \(Self.dur(o.seconds)) this block covers.")
                    Text(" · ")
                    // The bolt is an SF Symbol rather than the ⚡ emoji, which
                    // renders in full colour and breaks a line that is
                    // otherwise uniformly dimmed. As a symbol it inherits the
                    // foreground style, like the arrows beside it.
                    // The window is stated inline rather than left to the
                    // heading or to a tooltip. `.help` does not reliably fire
                    // inside a `MenuBarExtra(.window)` panel — it is not
                    // key/activating, so AppKit's tooltip tracking mostly does
                    // not run — and "hovering doesn't explain anything" is how
                    // that was found. The heading does scope the whole block,
                    // but twice now that has not been the connection a reader
                    // makes, and one short phrase is a cheap way to stop
                    // needing them to.
                    // Omitted when nothing was measurable. `accumulate` skips
                    // samples reporting no power, so hardware without a sensor
                    // reaches here with a zero sum — and `0.0 Wh in 2h 14m` is a
                    // measurement of zero, not the absence of one. The CLI
                    // already hides its Power line on `PowerCount == 0`.
                    if o.energyWh > 0 {
                        (Text(Image(systemName: "bolt.fill"))
                         + Text(" \(Self.wh(o.energyWh)) in \(Self.dur(o.seconds))"))
                            .help(energyHelp(o))
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(DW.textA(0.45))
            }
            .padding(.horizontal, 16).padding(.top, 12)
            // Load-bearing, per docs/macos-ui.md: "Observed" is a claim about
            // sample provenance, not about the app having been open, and
            // ordinary English hears the second one. Someone who quits for ten
            // minutes and comes back to "Observed 2h 14m" needs this reachable.
            .help("Covers seconds the dish recorded and DishWatch retrieved, including up to 15 min of catch-up after a gap. Longer gaps are excluded entirely.")
        }
    }

    /// Says the window out loud, and says which of the screen's two Wh figures
    /// this one is.
    ///
    /// There are two, deliberately, and they cover different spans: this total
    /// belongs to the Observed window, while the Power cell's belongs to a
    /// separate since-boot accumulator. Two watt-hour numbers a few points apart
    /// with no explanation is a worse problem than the one missing number this
    /// replaced, so each says what it measures and over how long.
    private func energyHelp(_ o: ObservedStats) -> String {
        let mean = o.seconds > 0 ? o.energyWh * 3600 / Double(o.seconds) : 0
        return """
        \(Self.wh(o.energyWh)) drawn over the \(Self.dur(o.seconds)) this block covers \
        — about \(String(format: "%.1f", mean)) W on average.
        """
    }

    private func observedLine(_ o: ObservedStats) -> String {
        "ping \(Int(o.pingAvg)) · \(Int(o.cleanPct))% clean · peak ↓\(Int(o.downPeak)) ↑\(Int(o.upPeak)) · \(String(format: "%.1f", o.powerAvg)) W"
    }

    /// Dish uptime, coarsening as it grows:
    ///
    ///     45s · 42m · 1h5m · 13h · 3d4h · 24d · 2mo14d · 1y3mo
    ///
    /// The old line was `%.1f h`, which spent its only decimal on the least
    /// useful end of the range: six minutes after a reboot it read "0.1 h", and
    /// a dish up for three weeks read "504.0 h". Neither is a number anyone
    /// converts in their head.
    ///
    /// Two rules, both about what a reader of an uptime figure wants:
    ///
    /// - The minor unit shows only while the major one is a single digit. "1h5m"
    ///   earns the detail; "13h 42m" does not, and those minutes churn on every
    ///   refresh for someone reading "about half a day". A zero minor unit is
    ///   dropped, so two hours exactly is "2h".
    /// - Seconds never pair with minutes, for the same reason — five minutes
    ///   after a reboot is "5m", not "5m12s".
    ///
    /// Distinct from `dur` on purpose: that one is the CLI's shared span format
    /// and keeps both units at every size. A month here is 30 days and a year is
    /// 12 of those; this is an uptime readout, not a calendar. Mirrors
    /// `state.UptimeDur` on the Go side.
    static func uptime(_ seconds: Int64) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return compound(h, "h", m % 60, "m") }
        let d = h / 24
        if d < 30 { return compound(d, "d", h % 24, "h") }
        let mo = d / 30
        if mo < 12 { return compound(mo, "mo", d % 30, "d") }
        return compound(mo / 12, "y", mo % 12, "mo")
    }

    /// Major unit plus the minor one, keeping the minor only while the major is
    /// a single digit and the minor is non-zero: "1h5m", "2h", "13h".
    private static func compound(_ major: Int64, _ majorUnit: String,
                                 _ minor: Int64, _ minorUnit: String) -> String {
        major < 10 && minor > 0
            ? "\(major)\(majorUnit)\(minor)\(minorUnit)"
            : "\(major)\(majorUnit)"
    }

    /// Matches the CLI's `HumanDur` so the two surfaces read the same.
    static func dur(_ s: Int64) -> String {
        if s < 60 { return "\(s)s" }
        let m = s / 60, h = m / 60, d = h / 24
        if m < 60 { return "\(m)m" }
        if h < 24 { return h > 0 && m % 60 > 0 ? "\(h)h \(m % 60)m" : "\(h)h" }
        return d > 0 && h % 24 > 0 ? "\(d)d \(h % 24)h" : "\(d)d"
    }

    /// Watt-hours for the Observed line: whole numbers past 10 Wh, one decimal
    /// below it, and kWh once the figure outgrows four digits — a dish left up
    /// for a month draws past 20 000 Wh, which is a number nobody parses.
    static func wh(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.1f kWh", v / 1000) }
        if v >= 10 { return "\(Int(v.rounded())) Wh" }
        return String(format: "%.1f Wh", v)
    }

    static func bytes(_ b: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = b, i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return i <= 1 ? "\(Int(v)) \(units[i])" : String(format: "%.1f %@", v, units[i])
    }

    @ViewBuilder
    private func sparkRow(_ row: SparkRow) -> some View {
        // A single point cannot be a trace, and `Spark` draws nothing for one —
        // so anything under two samples is a row with a label and no content.
        //
        // Traces for series the dish did not send are dropped, and a row left
        // with none is omitted rather than drawn blank. This is the other half
        // of `shortestSeries` in dashboard.go, which excludes an empty ring from
        // the covered-window figure so one missing ring cannot hide two good
        // traces. That exclusion is only honest if the absent row is *also*
        // gone — otherwise firmware with no `powerIn` gets a blank power row
        // under a heading claiming to cover it. Per trace, not per row, now that
        // one row carries two: a dish sending downlink and no uplink ring draws
        // the download line alone, with a legend that says so.
        let traces = drawn(row)
        if !traces.isEmpty {
            sparkRowBody(row, traces)
        }
    }

    private func sparkRowBody(_ row: SparkRow, _ drawn: [SparkTrace]) -> some View {
        let span = Spark.span(drawn)
        return HStack(spacing: 12) {
            rowLabel(row, drawn)
                .font(.system(size: 11)).foregroundStyle(DW.textA(0.55))
                .frame(width: 52, alignment: .leading)
            Spark(traces: drawn, baseline: baseline(row),
                  marker: scrub?.row == row ? scrub?.column : nil)
                .frame(height: 24)
                .overlay(scrubTarget(row, span: span))
            // Fixed, and wide enough for the longest of the three: the ↓↑ row's
            // `avg ↓12.4 ↑1.4` carries two figures where the others carry one.
            // Sized for all rows alike — a per-row width would step the charts'
            // right edges against each other, and a row losing its figure
            // entirely (no ring, no peak) would shift the sparklines above it.
            trailing(row, drawn, span: span)
                .font(.system(size: 11)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
                // `minimumScaleFactor` here is about *width* — the ↓↑ row
                // carries two figures in the same 82 pt as the others carry
                // one. It answers to height as well, and that was a bug you
                // could watch happen: squeeze the panel vertically and these
                // three figures gave up font size while every other label held,
                // so opening the detail row visibly shrank the word "avg" and
                // nothing else. Pinning the vertical size keeps the modifier
                // doing the job it was added for and no other.
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(DW.textA(0.45))
                .frame(width: 82, alignment: .trailing)
        }
    }

    /// Row names are units, not words. "Ping"/"Down"/"Power" put a word with two
    /// meanings in a column about link health: beside "Ping", "Down" reads as
    /// *outage*, and it is download throughput — the same number as the Download
    /// cell above.
    ///
    /// The ↓↑ row's arrows are also the chart's legend: they carry the trace
    /// colours, and nothing else on screen says which line is which. Built from
    /// the *drawn* traces so a row that lost an absent series does not keep
    /// advertising it.
    private func rowLabel(_ row: SparkRow, _ drawn: [SparkTrace]) -> Text {
        switch row {
        case .ping:  return Text("Ping ms")
        case .power: return Text("Power W")
        case .throughput:
            return drawn.reduce(Text("")) { $0 + Text($1.symbol).foregroundStyle($1.color) } + Text(" Mbps")
        }
    }

    /// The figure to the right of a trace: its window statistic normally, and
    /// the value under the pointer while that row is being scrubbed.
    ///
    /// A scrubbed figure is a *sample*, not a statistic, so it is the row's own
    /// unit under the pointer and nothing more.
    private func trailing(_ row: SparkRow, _ drawn: [SparkTrace], span: Int) -> Text {
        if let s = scrub, s.row == row {
            var out = Text("")
            var first = true
            for t in drawn {
                guard let v = Spark.sample(t, at: s.column, span: span) else { continue }
                if !first { out = out + Text(" ") }
                first = false
                let value = Text("\(t.symbol)\(Self.sampleText(row, v))")
                // The colour is what ties the number to its line; a single-trace
                // row has nothing to tie it to and stays in the dimmed default.
                out = out + (t.symbol.isEmpty ? value : value.foregroundStyle(t.color))
            }
            return out
        }
        switch row {
        case .ping:       return Text("avg \(Int(d.pingAvg)) ms")
        case .throughput: return Self.avgText(drawn)
        case .power:      return Text("avg \(String(format: "%.1f", d.powerAvg)) W")
        }
    }

    /// The ↓↑ row's idle figure: a **mean** across the window on screen, the
    /// same statistic its two neighbours show.
    ///
    /// A mean throughput on its own is the figure docs/macos-ui.md warns about —
    /// it measures utilization, so an idle second counts against a flawless link
    /// and `avg 3` can read as a broken dish. What makes it safe *here* is
    /// company. The chart it captions is right beside it, so the shape the mean
    /// flattens is on screen; the peak — the figure that does describe the
    /// link's capability — is in the Observed footer two blocks down; and the
    /// heading names the window. A lone `avg 3` in a summary cell has none of
    /// that, which is where the rule still applies.
    ///
    /// Zeros included, unlike ping and power: for those a zero means *not
    /// measured*, and for throughput it means a second in which nothing moved.
    ///
    /// Per direction, and only for traces actually drawn: same rule as the
    /// legend and the scrub readout, so firmware with no uplink ring does not
    /// get an `↑0.0` invented for it.
    private static func avgText(_ drawn: [SparkTrace]) -> Text {
        let means = drawn.compactMap { t in Spark.mean(t).map { (t, $0) } }
        guard !means.isEmpty else { return Text("") }
        var out = Text("avg")
        for (t, m) in means {
            let value = Text(" \(t.symbol)\(MenuBarField.compactMbps(m))")
            // The colour is what ties the number to its line; a single-trace row
            // has nothing to tie it to and stays in the dimmed default.
            out = out + (t.symbol.isEmpty ? value : value.foregroundStyle(t.color))
        }
        return out
    }

    /// The value under the pointer, in the row's own unit.
    ///
    /// Formatted, never converted through `Int`: `Int(Double)` traps on a value
    /// too large to represent, and this is the one number on screen that comes
    /// straight from a sample rather than from a bounded statistic.
    private static func sampleText(_ row: SparkRow, _ v: Double) -> String {
        switch row {
        case .ping:       return String(format: "%.0f ms", v.rounded())
        // The menu bar's rule, for the menu bar's reason: a decimal only below
        // 10 Mbps, where flat integers turn an idle-but-healthy link into ↓0.
        case .throughput: return MenuBarField.compactMbps(v)
        case .power:      return String(format: "%.1f W", v)
        }
    }

    /// The drag target over one chart.
    ///
    /// `minimumDistance: 0`, so a press with no movement already reads a value.
    /// It has to be a press: `.help` tooltips do not fire inside this panel and
    /// neither does hover tracking — the `MenuBarExtra(.window)` panel is
    /// non-activating, which is the finding docs/macos-ui.md records under
    /// *Tooltips are not a place to put information*. A click is the one thing
    /// the panel is known to receive, which is why its buttons work.
    private func scrubTarget(_ row: SparkRow, span: Int) -> some View {
        GeometryReader { g in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            scrub = Scrub(row: row,
                                          column: Spark.column(atX: v.location.x, width: g.size.width, span: span))
                        }
                        // Cleared on release rather than left pinned. The series
                        // shift left every poll, so a marker that outlived the
                        // gesture would sit on a different second a second later
                        // while still captioned with the old age.
                        .onEnded { _ in scrub = nil }
                )
        }
    }

    private var detailRow: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { detailExpanded.toggle() }
            } label: {
                HStack {
                    HStack(spacing: 16) {
                        // "Pointing", not "Aim". The hardware chip above now
                        // says "Aim by hand", which is a *capability* — and the
                        // same verb over a pair of live angles reads as an
                        // instruction to go set them, or as motors moving to
                        // them right now. One word, two facts, in one panel.
                        // Normalised here too. The dish reports azimuth as
                        // −180…180, and a leading minus on a compass bearing is
                        // the first half of the coordinate misreading.
                        Text("◎ Pointing \(Int(aimBearing.rounded()))° / \(Int(d.elevationDeg))°")
                        Text("⌖ GPS \(d.gpsValid ? "✓" : "✗") \(d.gpsSats)")
                        Text("⎈ \(d.ethMbps) Mbps")
                    }
                    .font(.system(size: 11.5)).foregroundStyle(DW.textA(0.6))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(DW.textA(0.35))
                        .rotationEffect(.degrees(detailExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if detailExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    // The plot sits beside the angles it draws, not under
                    // them. The confusion being fixed is that azimuth and
                    // elevation read as a coordinate when stacked above a GPS
                    // row; putting a compass ring in the same glance is what
                    // breaks that reading, and it only works if both are on
                    // screen together.
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            // "Bearing", not "Azimuth". Same number, and the
                            // one word a reader already knows means direction.
                            detailLine("Bearing", aimBearingText)
                            detailLine("Elevation", "\(Int(d.elevationDeg))° above horizon")
                            detailLine("GPS", "\(d.gpsValid ? "lock" : "no fix") · \(d.gpsSats) sats")
                            detailLine("Ethernet", "\(d.ethMbps) Mbps")
                        }
                        SkyPlot(azimuthDeg: d.azimuthDeg, elevationDeg: d.elevationDeg, size: 92)
                    }
                    Text(d.aimExplanation)
                        .font(.system(size: 11))
                        .foregroundStyle(DW.textA(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                    countryDetail
                    egressDetail
                    serviceDetail
                }
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    /// The dish's azimuth as a compass bearing, 0..<360.
    ///
    /// `-176°` is the dish's own convention (−180…180). A leading minus on
    /// something labelled as a direction is the first half of the coordinate
    /// misreading this block exists to close.
    private var aimBearing: Double {
        let b = d.azimuthDeg.truncatingRemainder(dividingBy: 360)
        return b < 0 ? b + 360 : b
    }

    /// Bearing as a figure and a named direction: `184° · S`.
    ///
    /// The compass point is what turns a number into a fact, but it earns its
    /// space only where there is room to read it — the expanded row, not the
    /// one-line strip, which already carries two other readings.
    private var aimBearingText: String {
        "\(Int(aimBearing.rounded()))° · \(DishData.compassPoint(aimBearing))"
    }

    /// The country badge again, with the sentence that says what it is not.
    ///
    /// Same reason `serviceDetail` exists and the same place, because it is the
    /// same kind of claim: a fact the dish reports about itself that reads like
    /// a fact about you. This was a `.help()` for one afternoon, which docs
    /// /macos-ui.md had already explained cannot work in this panel.
    @ViewBuilder private var countryDetail: some View {
        if let badge = d.countryBadge {
            Divider().background(DW.hairline).padding(.vertical, 2)
            detailLine("Country", badge)
            Text(d.countryHelp)
                .font(.system(size: 11))
                .foregroundStyle(DW.textA(0.45))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Where this Mac's traffic leaves the network — directly under the dish's
    /// own country, because the pair only means anything together.
    ///
    /// The country above answers *what does the terminal think it is licensed
    /// under*. This answers *where do my packets actually come out*, and the
    /// interesting reading is when the second one says they are not coming out
    /// of the dish at all. Nothing else in the panel can notice a laptop that
    /// has quietly fallen back to a hotspot while a healthy dish sits beside it
    /// reporting 200 Mbps it is not carrying.
    ///
    /// **It starts as a button, not as a reading**, and that is a privacy
    /// decision rather than a layout one. Every other row here is a fact the
    /// app already has; this one has to be fetched from a server that is not
    /// the dish, so nothing happens until the user presses this. There is no
    /// second way in. The host is named on screen before the first press, not
    /// buried in a privacy policy, because a disclosure the user cannot see at
    /// the moment of consent is not one.
    @ViewBuilder private var egressDetail: some View {
        Divider().background(DW.hairline).padding(.vertical, 2)
        switch store.egress {
        case .untried:
            egressPrompt(button: "Check",
                         note: "Asks \(store.egressHost) which public address this Mac reaches the internet from — the one reading here that leaves your network. Nothing is sent until you press it.")
        case .checking:
            HStack {
                Text("Exit").font(.system(size: 11.5)).foregroundStyle(DW.textA(0.45))
                Spacer()
                Text("checking…").font(.system(size: 11.5)).foregroundStyle(DW.textA(0.5))
            }
        case .ok(let e, let at):
            HStack {
                Text("Exit").font(.system(size: 11.5)).foregroundStyle(DW.textA(0.45))
                Spacer()
                Text(e.summary).font(.system(size: 11.5)).foregroundStyle(DW.textA(0.75))
                // Small, and to the right of the reading it replaces. A press
                // is how you ask again after changing networks, which is the
                // only moment the answer is wrong rather than merely old.
                Button { store.checkEgress() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(DW.textA(0.4))
                        .padding(.leading, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // The address, the AS and the age of the reading. The age matters
            // more here than anywhere else on the panel: everything else is a
            // second old, and this stands untouched until the next press —
            // an hour-old fact sitting in a column of live numbers.
            egressNote("\(e.detail) · checked \(Self.age(of: at))", tone: 0.45)
            if let caution = e.caution {
                egressNote(caution, tone: 0.8, color: DW.amber)
            }
        case .failed(let why):
            egressPrompt(button: "Retry", note: "Could not check: \(why).", color: DW.amber)
        }
    }

    /// The un-checked and failed states: a label, a button, and one sentence.
    private func egressPrompt(button: String, note: String, color: Color = DW.textA(0.45)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Exit").font(.system(size: 11.5)).foregroundStyle(DW.textA(0.45))
                Spacer()
                DWButton(title: button) { store.checkEgress() }
            }
            egressNote(note, tone: 1, color: color)
        }
    }

    private func egressNote(_ text: String, tone: Double, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color.map { $0.opacity(tone) } ?? DW.textA(tone))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "just now" / "4m ago" for the exit reading's age.
    ///
    /// A local copy rather than `AppState.lastGoodAgoText`, which is about the
    /// poll loop and is phrased for a footer. Same words, different subject.
    static func age(of date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    /// The service class again, this time with the sentence that says what it
    /// is — and, more usefully, what it is not.
    ///
    /// Repeating the hero's value is deliberate. The rule this panel keeps is
    /// that two *figures* over different windows must not sit near each other
    /// unexplained; a fact and its gloss are not that, and an explanation with
    /// no visible referent beside it is a worse read than one short repeat.
    ///
    /// On screen rather than in a `.help`: tooltips do not reliably fire inside
    /// a `MenuBarExtra(.window)` panel — it is non-activating, so AppKit's
    /// tracking mostly does not run. That is the finding docs/macos-ui.md
    /// records under *Tooltips are not a place to put information*, and it is
    /// why the energy explanation moved out of one. The disclosure triangle is
    /// a click, and clicks are the one thing this panel is known to receive.
    @ViewBuilder private var serviceDetail: some View {
        if let service = d.serviceLine {
            Divider().background(DW.hairline).padding(.vertical, 2)
            detailLine("Service", service)
            if let blocked = d.serviceBlockedReason {
                detailLine("Blocked", blocked)
            }
            if let why = d.serviceExplanation {
                Text(why)
                    .font(.system(size: 11))
                    .foregroundStyle(DW.textA(0.45))
                    // Wraps to as many lines as it needs. Without this the
                    // paragraph is handed one line inside a VStack and truncates
                    // mid-caveat, which loses precisely the half that matters.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var heroLabel: String {
        store.hasLoaded ? d.stateLabel : "Connecting…"
    }

    private var dotColor: Color {
        guard store.hasLoaded else { return DW.textA(0.4) }
        switch d.state {
        case .connected: return DW.green
        case .offline, .disabled: return DW.red
        case .weak: return DW.amber
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11.5)).foregroundStyle(DW.textA(0.45))
            Spacer()
            Text(value).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(DW.textA(0.75))
        }
    }

    private var footer: some View {
        // The status word comes from AppState.quality, which distinguishes
        // "the transport call returned" from "the dish is up". Those were
        // conflated, and because the helper reports an unreachable dish as a
        // *successful* poll carrying an Offline dashboard, the result was a hero
        // reading Offline directly above a footer reading live.
        let status: String
        switch store.quality {
        case .sample:            status = "sample data — not a real dish"
        case .brokenInstall:     status = "helper missing — reinstall DishWatch"
        case .loading:           status = "connecting…"
        case .live:              status = "live"
        case .disabled:          status = "service disabled"
        case .offline:           status = "no dish at this address"
        case .stale:
            status = store.lastGoodAgoText.map { "stale — last reading \($0)" } ?? "stale"
        }
        // Build identity trails the data status, and is deliberately *not*
        // coloured by it. The amber above means "do not trust this reading";
        // whether the bundle is a dev build is a different axis entirely — a
        // local build shows live data as truthfully as the cask does — and
        // folding the two into one colour would make a dev build look like a
        // data fault. Dimmer than the address, since it changes far less often
        // than anything else on the line.
        let buildLabel = build.footerLabel
        return HStack {
            Text("\(d.dishAddr) · \(status)")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(store.quality.isTrustworthy ? DW.textA(0.38) : DW.amber.opacity(0.8))
            if let buildLabel {
                Text("· \(buildLabel)")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(DW.textA(0.3))
                    // The address and the status are the load-bearing half of
                    // this line; if anything has to give under a long dev
                    // version string it is this. Shrinking beats pushing the
                    // Pin button off the panel, and beats truncating an IP.
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 6)
            // Pin alone. Reboot used to sit here at the same weight, which put
            // a rare destructive action one stray click from a daily toggle —
            // see AppMenuButton.reboot, which now carries it.
            //
            // The only window we own to "open" is the always-on-top compact
            // widget — the dish has no real web app to launch.
            DWButton(title: store.pinnedWidget ? "Unpin" : "Pin", prominent: true) {
                store.pinnedWidget.toggle()
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 15)
    }
}

/// One cell of the 2×2 metric grid.
struct MetricCell: View {
    var label: String
    var value: String
    var unit: String
    var sub: String? = nil
    var barFrac: Double? = nil
    var barColor: Color = DW.down

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: label)
            (Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit()
             + Text(" \(unit)").font(.system(size: 11, weight: .regular)).foregroundColor(DW.textA(0.5)))
                .padding(.top, 4)
            if let barFrac {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(barColor).frame(width: max(2, g.size.width * barFrac))
                    }
                }
                .frame(height: 3).padding(.top, 7)
            } else if let sub {
                Text(sub).font(.system(size: 11)).foregroundStyle(DW.textA(0.45)).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(DW.cellBG.opacity(0.7))
    }
}
