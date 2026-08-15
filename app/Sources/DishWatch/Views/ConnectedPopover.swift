import SwiftUI

/// Screen A — connected, on mains. Gauge + metric grid + sparklines + detail.
struct ConnectedPopover: View {
    var d: DishData
    @Binding var showSettings: Bool
    @EnvironmentObject var store: AppState
    @State private var detailExpanded = false
    @State private var confirmReboot = false

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

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                SignalBars(color: DW.cyan, height: 13, barWidth: 3, fraction: Double(d.signalScore) / 100)
                Text("DishWatch").font(.system(size: 14, weight: .bold))
            }
            Spacer()
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
                Text("up \(d.uptimeHours, specifier: "%.1f") h · boots \(d.boots) · \(d.hardwareShort)")
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
                MetricCell(label: "Upload", value: String(format: "%.1f", d.upMbps), unit: "Mbps",
                           barFrac: d.upBarFrac, barColor: DW.down)
            }
            GridRow {
                MetricCell(label: "Ping", value: "\(Int(d.pingMs))", unit: "ms",
                           sub: "drop \(String(format: "%.1f", d.dropPct))% · \(d.noiseOK ? "noise ✓" : "noise ✗")")
                MetricCell(label: "Power", value: String(format: "%.1f", d.powerW), unit: "W",
                           sub: energyLine, subHelp: energyCellHelp)
            }
        }
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    /// Spells out the window under the Power cell's total, which the cell has
    /// no room to state and which differs from the Observed block's.
    private var energyCellHelp: String {
        let wh = String(format: "%.1f", d.energyWhSinceBoot)
        if d.energyCoversBoot {
            return "\(wh) Wh drawn since the dish last booted, from samples covering essentially the whole of it."
        }
        if d.energyAvgW > 0, d.energySeconds > 0 {
            return """
            \(wh) Wh measured across \(Self.span(Int(d.energySeconds))) of samples — \
            not the whole boot, because energy only accumulates while DishWatch is \
            retrieving readings. The true since-boot figure is higher.
            """
        }
        return """
        \(wh) Wh measured. How long that covers is not known for this boot, so no \
        average is offered — the sample count and the total disagree, and the next \
        reboot resets both.
        """
    }

    /// Test seam for `energyLine`, which is private and not a `View`.
    var energyLineForTesting: String { energyLine }
    var energyCellHelpForTesting: String { energyCellHelp }
    func energyHelpForTesting(_ o: ObservedStats) -> String { energyHelp(o) }

    private var sparklines: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                // The window the *data* covers, not the one that was requested.
                // A dish two minutes past a reboot answers a 15-minute request
                // with two minutes of ring, and captioning that "15 m" would be
                // the same class of lie as the `max` figure this block already
                // lost once.
                SectionLabel(text: coveredLabel).tracking(0.8)
                    .help("Covers the last \(Self.span(d.seriesSeconds)) the dish has in its own history ring — which is all of it after a reboot, however wide a window you pick.")
                Spacer()
                windowPicker
            }
            // Row names are units, not words. "Ping"/"Down"/"Power" put a word
            // with two meanings in a column about link health: beside "Ping",
            // "Down" reads as *outage*, and it is download throughput — the same
            // number as the Download cell above.
            sparkRow("Ping ms", d.pingSeries, DW.cyan, "avg \(Int(d.pingAvg)) ms")
            // No trailing figure on ↓. It used to read `max <n>`, a
            // 60-second maximum presented as a peak — the defect docs/macos-ui.md
            // opens with. The sparkline already shows the shape, and the
            // Observed footer below carries a peak that means something.
            sparkRow("↓ Mbps", d.downSeries, DW.down, nil)
            sparkRow("Power W", d.powerSeries, DW.amber, "avg \(String(format: "%.1f", d.powerAvg)) W")
            // Rows for series the dish did not send are omitted, not drawn
            // blank. This is the other half of `shortestSeries` in dashboard.go,
            // which excludes an empty ring from the covered-window figure so one
            // missing ring cannot hide two good traces. That exclusion is only
            // honest if the absent row is *also* gone — otherwise firmware with
            // no `powerIn` gets a blank power row under a heading claiming to
            // cover it.
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
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
                    (Text(Image(systemName: "bolt.fill")) + Text(" \(Self.wh(o.energyWh))"))
                        .help(energyHelp(o))
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
        The figure under Power is the separate since-boot total.
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
    private func sparkRow(_ name: String, _ series: [Double], _ color: Color, _ trailing: String?) -> some View {
        // A single point cannot be a trace, and `Spark` draws nothing for one —
        // so anything under two samples is a row with a label and no content.
        if series.count > 1 {
            sparkRowBody(name, series, color, trailing)
        }
    }

    private func sparkRowBody(_ name: String, _ series: [Double], _ color: Color, _ trailing: String?) -> some View {
        HStack(spacing: 12) {
            Text(name).font(.system(size: 11)).foregroundStyle(DW.textA(0.55)).frame(width: 52, alignment: .leading)
            Spark(values: series, color: color).frame(height: 24)
            // Keeps the fixed width even when there is no trailing figure, so
            // dropping one row's label does not shift the sparklines above it.
            Text(trailing ?? "").font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(DW.textA(0.45)).frame(width: 60, alignment: .trailing)
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
    /// Tooltip for the sub-label. Optional because most sub-labels restate
    /// something already on screen; the energy one names a window that is not
    /// written anywhere in the cell.
    var subHelp: String? = nil
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
                    .help(subHelp ?? "")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(DW.cellBG.opacity(0.7))
    }
}
