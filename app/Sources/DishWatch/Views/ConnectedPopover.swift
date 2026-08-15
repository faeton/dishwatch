import SwiftUI

/// Screen A — connected, on mains. Gauge + metric grid + sparklines + detail.
struct ConnectedPopover: View {
    var d: DishData
    @Binding var showSettings: Bool
    @EnvironmentObject var store: AppState
    @State private var detailExpanded = false
    @State private var confirmReboot = false
    /// Non-nil only while a drag is on one of the sparklines.
    @State private var scrub: Scrub?

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

            actionBanner
            footer
        }
        .foregroundStyle(DW.text)
        .overlay(TopGlow(color: DW.cyan), alignment: .top)
        .confirmationDialog("Reboot the dish?", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("Reboot", role: .destructive) { Task { await store.reboot() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The dish will drop the connection for ~1–2 minutes.")
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

    /// Title row, and the width beside it spent on *which dish this is*.
    ///
    /// The chip sits here rather than in the hero because the hero's lines are
    /// about this session — uptime, boots, firmware — and the hardware is not.
    /// It is the one fact on screen that never changes between polls, and the
    /// empty run between the app name and the clock was the only place with
    /// room for a picture of it.
    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                SignalBars(color: DW.cyan, height: 13, barWidth: 3, fraction: Double(d.signalScore) / 100)
                Text("DishWatch").font(.system(size: 14, weight: .bold))
            }
            Spacer(minLength: 8)
            HardwareChip(model: d.hardwareShort, aim: d.hardwareAim)
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                Text(Date.now, format: .dateTime.hour().minute().second())
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(DW.textA(0.5))
                AppMenuButton(showSettings: $showSettings, refresh: { Task { await store.refresh() } })
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
                // The model used to trail this line. It moved to the header
                // chip, which says the same word beside a picture of the thing
                // and has room for the half that was missing — whether the
                // panel aims itself. Repeating it here would be the only
                // duplicated fact in the panel.
                Text("up \(d.uptimeHours, specifier: "%.1f") h · boots \(d.boots)")
                    .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(DW.textA(0.55))
                    .padding(.top, 7)
                Text("\(d.deviceId) · fw \(d.firmware)")
                    .font(.system(size: 11.5)).foregroundStyle(DW.textA(0.38))
                    .padding(.top, 2)
            }
            Spacer()
            SignalGauge(score: d.signalScore, size: 78)
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 16)
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
            return [SparkTrace(symbol: "↓", values: d.downSeries, color: DW.down,
                               fillOpacity: 0.5),
                    SparkTrace(symbol: "↑", values: d.upSeries, color: DW.up,
                               filled: false, width: 1.7)]
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
            // Keeps the fixed width even when there is no trailing figure, so
            // dropping one row's label does not shift the sparklines above it.
            trailing(row, drawn, span: span)
                .font(.system(size: 11)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(DW.textA(0.45))
                .frame(width: 60, alignment: .trailing)
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
    /// A scrubbed figure is a *sample*, not a statistic, which is the only
    /// reason the ↓↑ row may show one at all. Its idle trailing stays empty on
    /// purpose — a mean throughput there reads as capability, the defect
    /// docs/macos-ui.md opens with — and naming one second of the trace claims
    /// nothing of the sort.
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
        case .throughput: return Text("")
        case .power:      return Text("avg \(String(format: "%.1f", d.powerAvg)) W")
        }
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
                        Text("◎ Aim \(Int(d.azimuthDeg))° / \(Int(d.elevationDeg))°")
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
                    detailLine("Azimuth", "\(Int(d.azimuthDeg))°")
                    detailLine("Elevation", "\(Int(d.elevationDeg))°")
                    detailLine("GPS", "\(d.gpsValid ? "lock" : "no fix") · \(d.gpsSats) sats")
                    detailLine("Ethernet", "\(d.ethMbps) Mbps")
                }
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
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
        return HStack {
            Text("\(d.dishAddr) · \(status)")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(store.quality.isTrustworthy ? DW.textA(0.38) : DW.amber.opacity(0.8))
            Spacer()
            HStack(spacing: 7) {
                DWButton(title: "Reboot") { confirmReboot = true }
                // The only window we own to "open" is the always-on-top compact
                // widget — the dish has no real web app to launch.
                DWButton(title: store.pinnedWidget ? "Unpin" : "Pin", prominent: true) {
                    store.pinnedWidget.toggle()
                }
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
