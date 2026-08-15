import XCTest
@testable import DishWatch

/// The menu bar is the app's primary surface and the one with the least room,
/// so what it draws is now a set of user-chosen fields rather than one hardcoded
/// value. Two things are worth pinning: that a field renders what it claims to,
/// and that an upgrading user's bar does not silently change under them.
@MainActor
final class MenuBarTests: XCTestCase {

    private struct Fixed: DishProvider {
        let value: DishData
        func poll(window: Int) async throws -> DishData { value }
    }

    /// A `UserDefaults` nobody else is using, so these tests neither read nor
    /// corrupt the developer's real settings.
    private func scratchDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "dishwatch.tests.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - field rendering

    func testFieldsRenderTheirOwnValue() {
        var d = DishData.sample
        d.pingMs = 31
        d.downMbps = 142.5
        d.upMbps = 14.2
        d.signalScore = 86
        d.powerW = 23.4

        XCTAssertEqual(MenuBarField.ping.text(d), "31ms")
        XCTAssertEqual(MenuBarField.down.text(d), "↓143", "rounded, not truncated — 142.5 is nearer 143")
        XCTAssertEqual(MenuBarField.up.text(d), "↑14")
        XCTAssertEqual(MenuBarField.signal.text(d), "86")
        XCTAssertEqual(MenuBarField.power.text(d), "23W")
        XCTAssertNil(MenuBarField.pingSpark.text(d), "the sparkline is not text")
    }

    /// Whole Mbps everywhere rendered an idle-but-healthy link as `↓0 ↑0`, which
    /// reads as "nothing is flowing". The decimal is spent only where it changes
    /// that reading.
    func testThroughputKeepsADecimalOnlyWhereItChangesTheMeaning() {
        XCTAssertEqual(MenuBarField.compactMbps(0), "0.0")
        XCTAssertEqual(MenuBarField.compactMbps(0.34), "0.3")
        XCTAssertEqual(MenuBarField.compactMbps(0.4), "0.4", "an idle link must not read as a dead one")
        XCTAssertEqual(MenuBarField.compactMbps(5.24), "5.2")
        XCTAssertEqual(MenuBarField.compactMbps(9.94), "9.9")

        // At two digits the tenths stop earning their width.
        XCTAssertEqual(MenuBarField.compactMbps(9.96), "10", "rounds before choosing the format — never the wider '10.0'")
        XCTAssertEqual(MenuBarField.compactMbps(17.4), "17")
        XCTAssertEqual(MenuBarField.compactMbps(142.5), "143")

        var d = DishData.sample
        d.downMbps = 0.3
        d.upMbps = 0.4
        XCTAssertEqual(MenuBarField.down.text(d), "↓0.3")
        XCTAssertEqual(MenuBarField.up.text(d), "↑0.4")
    }

    /// A 0% battery and no battery are different facts. The bar has room for one
    /// of them and it is not the false one.
    func testBatteryFieldIsSilentOffABank() {
        var d = DishData.sample
        d.bankAnchored = false
        d.bankPct = 0
        XCTAssertNil(MenuBarField.battery.text(d))

        d.bankAnchored = true
        d.bankPct = 78
        XCTAssertEqual(MenuBarField.battery.text(d), "78%")
    }

    /// Render order comes from `allCases`, not from the order boxes were ticked,
    /// so the bar does not reshuffle itself when a field is toggled.
    func testReadoutOrderIsFixed() async {
        var d = DishData.sample
        d.bankAnchored = false
        let s = AppState(provider: Fixed(value: d))
        await s.refresh()

        s.menuBarFields = [.power, .down, .ping, .up]
        XCTAssertEqual(s.menuBarTexts.map(\.field), [.ping, .down, .up, .power])

        // Inserting one does not move the others.
        s.menuBarFields.insert(.signal)
        XCTAssertEqual(s.menuBarTexts.map(\.field), [.ping, .down, .up, .signal, .power])
    }

    /// The battery field is on by default, and must contribute nothing at all —
    /// not an empty string, not a stray separator — while the dish is on mains.
    func testSilentFieldsAreAbsentFromTheJoinedText() async {
        var d = DishData.sample
        d.bankAnchored = false
        d.pingMs = 31
        d.downMbps = 142.5
        d.upMbps = 14.2
        let s = AppState(provider: Fixed(value: d))
        await s.refresh()
        s.menuBarFields = AppState.defaultFields

        XCTAssertEqual(s.menuBarText, "31ms ↓143 ↑14")
    }

    // MARK: - migration

    /// An upgrading user had signal bars with the score appended. That is
    /// representable exactly, and anything else silently redecorates a menu bar
    /// they had already configured.
    func testUpgradeFromShowValuePreservesTheScore() {
        let d = scratchDefaults()
        d.set("Signal bars", forKey: "iconMode")
        d.set(true, forKey: "showValue")

        let s = AppState(provider: Fixed(value: .sample), defaults: d)
        XCTAssertEqual(s.iconMode, .signalBars)
        XCTAssertEqual(s.menuBarFields, [.signal])
    }

    func testUpgradeWithShowValueOffKeepsABareGlyph() {
        let d = scratchDefaults()
        d.set("Dish arc", forKey: "iconMode")
        d.set(false, forKey: "showValue")

        let s = AppState(provider: Fixed(value: .sample), defaults: d)
        XCTAssertEqual(s.iconMode, .dishArc)
        XCTAssertTrue(s.menuBarFields.isEmpty)
    }

    /// The retired "Data readout" mode drew "31ms" *instead of* a glyph. Its
    /// replacement is no glyph plus the ping field — not signal bars with a
    /// number bolted on, which is what an unmigrated `IconMode(rawValue:)`
    /// fallback would have produced.
    func testDataReadoutMigratesToNoGlyphPlusPing() {
        let d = scratchDefaults()
        d.set("Data readout", forKey: "iconMode")

        let s = AppState(provider: Fixed(value: .sample), defaults: d)
        XCTAssertEqual(s.iconMode, .noGlyph)
        XCTAssertEqual(s.menuBarFields, [.ping])
    }

    /// Migration runs once and is written back, so a later launch reads the
    /// stored fields rather than re-deriving them from a legacy key that the
    /// user may since have changed away from.
    func testMigrationIsPersisted() {
        let d = scratchDefaults()
        d.set("Data readout", forKey: "iconMode")
        _ = AppState(provider: Fixed(value: .sample), defaults: d)

        XCTAssertEqual(d.string(forKey: "iconMode"), IconMode.noGlyph.rawValue)
        XCTAssertEqual(d.array(forKey: "menuBarFields") as? [String], [MenuBarField.ping.rawValue])
    }

    /// A genuinely new install — *neither* legacy key ever written — is the only
    /// case that gets the richer default.
    func testFreshInstallGetsTheDefaultFields() {
        let s = AppState(provider: Fixed(value: .sample), defaults: scratchDefaults())
        XCTAssertEqual(s.iconMode, .signalBars)
        XCTAssertEqual(s.menuBarFields, AppState.defaultFields)
    }

    /// The regression this whole function keeps having: a *new* install that
    /// touches only the glyph picker.
    ///
    /// `init` does not fire `didSet`, so a fresh launch used to write nothing;
    /// `iconMode.didSet` then writes `iconMode` alone, and the resulting
    /// `{iconMode, no fields, no showValue}` domain is shaped exactly like a
    /// pre-fields upgrade. The next launch read the absent `showValue` as its
    /// old default of `true` and replaced the four-field default with the signal
    /// score. Reachable by tapping the glyph you already had selected.
    func testFreshInstallSurvivesTouchingOnlyTheGlyphPicker() {
        let d = scratchDefaults()
        let first = AppState(provider: Fixed(value: .sample), defaults: d)
        XCTAssertEqual(first.menuBarFields, AppState.defaultFields)
        XCTAssertNotNil(d.array(forKey: "menuBarFields"),
                        "a fresh install must write its resolved readout, or the next launch cannot tell it from a legacy domain")

        first.iconMode = .dishArc   // the one Settings tap that used to be fatal

        let second = AppState(provider: Fixed(value: .sample), defaults: d)
        XCTAssertEqual(second.iconMode, .dishArc)
        XCTAssertEqual(second.menuBarFields, AppState.defaultFields,
                       "changing the glyph must not silently collapse the readout to [.signal]")
    }

    /// Both legacy keys were written only by their own `didSet`, so a user who
    /// turned *Show value* off and never opened the glyph picker has `showValue`
    /// and **no** `iconMode`. That read as a fresh install and replaced their
    /// bare glyph with the four-field default — the exact silent redecoration
    /// the migration exists to prevent.
    func testUpgradeWithShowValueButNoStoredIconMode() {
        let off = scratchDefaults("showValueOffNoIcon")
        off.set(false, forKey: "showValue")
        let a = AppState(provider: Fixed(value: .sample), defaults: off)
        XCTAssertEqual(a.iconMode, .signalBars, "they never moved off the old default glyph")
        XCTAssertTrue(a.menuBarFields.isEmpty, "they asked for a bare glyph and must keep one")

        let on = scratchDefaults("showValueOnNoIcon")
        on.set(true, forKey: "showValue")
        let b = AppState(provider: Fixed(value: .sample), defaults: on)
        XCTAssertEqual(b.menuBarFields, [.signal])
    }

    /// A field written by a newer build is dropped, not fatal, and does not take
    /// the rest of the setting with it.
    func testUnknownStoredFieldIsIgnored() {
        let d = scratchDefaults()
        d.set("Signal bars", forKey: "iconMode")
        d.set(["ping", "quantumFlux", "down"], forKey: "menuBarFields")

        let s = AppState(provider: Fixed(value: .sample), defaults: d)
        XCTAssertEqual(s.menuBarFields, [.ping, .down])
    }

    /// An empty readout with no glyph would be a zero-width status item —
    /// invisible, and with nothing left to click to undo it.
    func testEmptyReadoutWithNoGlyphStillDrawsSomething() async {
        let s = AppState(provider: Fixed(value: .sample), defaults: scratchDefaults())
        s.iconMode = .noGlyph
        s.menuBarFields = []
        await s.refresh()

        // Ink, not bounds. `MenuBarIconContent` sets `frame(height: 15)` and
        // horizontal padding unconditionally, so a completely empty status item
        // still reports a non-zero size — the previous assertion passed whether
        // or not the fallback glyph existed.
        XCTAssertGreaterThan(Self.opaquePixels(MenuBarLabel.render(store: s)), 0,
                             "the fallback glyph is what keeps Settings reachable")
    }

    /// Count of non-transparent pixels — the template image carries its shape
    /// entirely in the alpha channel, so this is what "draws something" means.
    private static func opaquePixels(_ img: NSImage) -> Int {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return 0 }
        var n = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                n += 1
            }
        }
        return n
    }

    // MARK: - the glyph cache key

    /// The cache key must not be coarser than the drawing, or the bar freezes:
    /// the glyph changes, the key does not, and the stale image is served
    /// forever. These pin the two quantities that shipped mismatched.

    /// `SignalBars` lights a bar at fractions .125/.375/.625/.875 — scores 12.5,
    /// 37.5, 62.5, 87.5. None is a multiple of 5, so the old `score / 5` bucket
    /// straddled every one of them: 12 and 13 shared a bucket and drew a
    /// different number of bars.
    func testSignalKeyTracksTheBarsActuallyDrawn() {
        XCTAssertNotEqual(SignalBars.litBars(fraction: 0.12), SignalBars.litBars(fraction: 0.13),
                          "12 and 13 light a different number of bars and must key differently")
        XCTAssertEqual(12 / 5, 13 / 5, "…which the retired bucket could not express")

        // Within one lit-bar step the key may legitimately hold still.
        XCTAssertEqual(SignalBars.litBars(fraction: 0.20), SignalBars.litBars(fraction: 0.30))
    }

    /// The one that matters: drive the real cache and check it does not serve a
    /// stale glyph. The assertions above are about `litBars` in isolation and
    /// would still pass if `GlyphKey` stopped using it.
    func testCacheRedrawsWhenTheGlyphChanges() async {
        func bar(signal: Int) async -> Data? {
            var d = DishData.sample
            d.signalScore = signal
            d.onBattery = false
            let s = AppState(provider: Fixed(value: d), defaults: scratchDefaults("cache\(signal)"))
            s.iconMode = .signalBars
            s.menuBarFields = []   // isolate the glyph: no text in the key
            await s.refresh()
            return MenuBarLabel.cachedRender(store: s).tiffRepresentation
        }

        // 12 → 13 lights a bar. The retired `score / 5` bucket put both in
        // bucket 2, so the second call returned the first call's image.
        let a = await bar(signal: 12)
        let b = await bar(signal: 13)
        XCTAssertNotNil(a)
        XCTAssertNotEqual(a, b, "a score that lights another bar must invalidate the cached image")

        // And it still caches: an unchanged input must not re-rasterise into a
        // different image.
        let again = await bar(signal: 13)
        XCTAssertEqual(again, b)
    }

    /// `MenuBarSpark.plotted` is the single definition of the trace: the view
    /// plots its output and `GlyphKey` stores it. The invariant is not "the key
    /// is fine-grained" but "the key is exactly the drawing", which holds by
    /// construction — so what is worth pinning is that the quantisation it
    /// applies is the *deliberate* one and lands on the drawing side too.
    func testSparkQuantisationIsSharedNotJustKeyed() {
        // Sub-millisecond jitter renders flat. Load-bearing, not a concession:
        // the trace auto-ranges over its own min and max, so without this a link
        // sitting at 10.1–10.4 ms would draw full-height noise and read as a
        // problem. Because the *view* plots this array too, flat is what is
        // actually drawn — the key is not claiming a stillness the icon lacks.
        XCTAssertEqual(MenuBarSpark.plotted([10.1, 10.4]), MenuBarSpark.plotted([10.4, 10.1]))
        XCTAssertEqual(Set(MenuBarSpark.plotted([10.1, 10.4])).count, 1, "…and it is flat, not merely equal")

        // A real move still separates them, in both directions.
        XCTAssertNotEqual(MenuBarSpark.plotted([30, 45]), MenuBarSpark.plotted([45, 30]))

        // And it is a tail: a 900-point series must not key on 900 points.
        let long = (0..<900).map(Double.init)
        XCTAssertEqual(MenuBarSpark.plotted(long).count, MenuBarSpark.samples)
        XCTAssertEqual(MenuBarSpark.plotted(long).last, 899, "the tail is the newest end")
    }

    // MARK: - history window

    /// Asserted as a range, not as a copy of the literal. The previous version
    /// compared the constant to itself, which cannot fail and therefore said
    /// nothing about the property that matters: every offered window has to sit
    /// inside the bounds `clampSeriesWindow` enforces on the Go side, or the
    /// picker offers a setting the data can never satisfy.
    func testHistoryWindowsFitTheDishRing() {
        XCTAssertFalse(AppState.historyWindows.isEmpty)
        for w in AppState.historyWindows {
            XCTAssertGreaterThanOrEqual(w, 60, "below the floor Go clamps up to, so the picker would lie")
            XCTAssertLessThanOrEqual(w, 900, "the dish's ring is 900 samples; more would caption data that cannot exist")
        }
        XCTAssertEqual(AppState.historyWindows, AppState.historyWindows.sorted(),
                       "the picker renders them in array order")
    }

    /// The span label is deliberately not `dur`: 60 s beside "5m" and "15m" has
    /// to read "60s", not "1m", or the three buttons look like a broken scale.
    func testSpanLabelsTheShortestWindowInSeconds() {
        XCTAssertEqual(ConnectedPopover.span(60), "60s")
        XCTAssertEqual(ConnectedPopover.span(119), "119s")
        XCTAssertEqual(ConnectedPopover.span(300), "5m")
        XCTAssertEqual(ConnectedPopover.span(900), "15m")
    }

    /// The window the user picked is what gets requested. This was a per-poll
    /// argument rather than provider state precisely so a change between two
    /// polls is answered by the next frame.
    func testPollRequestsTheSelectedWindow() async {
        // Locked, because the background poll loop calls this concurrently with
        // the explicit refresh below.
        final class Recording: DishProvider, @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [Int] = []
            var windows: [Int] { lock.withLock { seen } }
            func poll(window: Int) async throws -> DishData {
                lock.withLock { seen.append(window) }
                return .sample
            }
        }
        let p = Recording()
        let s = AppState(provider: p, defaults: scratchDefaults())
        s.historyWindow = 900

        // Deliberately no explicit `refresh()`. Calling one here made the test
        // pass even with the `didSet` removed entirely — it was asserting that
        // `refresh` reads `historyWindow`, not that changing the window fetches
        // anything. The poll `didSet` starts is the whole behaviour under test,
        // so wait for it instead.
        let deadline = Date().addingTimeInterval(3)
        while p.windows.last != 900 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(p.windows.last, 900,
                       "changing the window must poll for it, not wait for the next tick")
    }
}

/// The energy readout says only as much as the samples support.
///
/// It was one unconditional string, `"%.1f Wh since boot"`, and the accumulator
/// behind it integrates only samples actually retrieved — so after any gap it
/// holds an under-count wearing the label of a total. Measured on a real dish:
/// `90.3 Wh since boot` for a boot that had drawn roughly 900.
@MainActor
final class EnergyLineTests: XCTestCase {

    private func line(_ d: DishData) -> String {
        // Rendered through the view's own logic, via the same mirror the popover
        // uses, so the test cannot drift from what is drawn.
        ConnectedPopover(d: d, showSettings: .constant(false)).energyLineForTesting
    }

    func testCoveredBootMayClaimTheBoot() {
        var d = DishData.sample
        d.energyWhSinceBoot = 894.2
        d.energyCoversBoot = true
        XCTAssertEqual(line(d), "894.2 Wh since boot")
    }

    /// The common case, and the one that used to lie.
    func testPartialCoverageNamesItsOwnWindowInstead() {
        var d = DishData.sample
        d.energyWhSinceBoot = 90.3
        d.energyCoversBoot = false
        d.energySeconds = 10_800
        d.energyAvgW = 30.1

        let s = line(d)
        XCTAssertFalse(s.contains("since boot"), "it does not cover the boot: \(s)")
        XCTAssertTrue(s.contains("90.3 Wh"))
        XCTAssertTrue(s.contains("3h"), "names the window it does cover: \(s)")
        XCTAssertTrue(s.contains("30.1 W"))
    }

    /// A total with no usable denominator — nothing counted yet, or a count and
    /// a total that cannot both be true (`state.MaxPlausibleW`). Quote the
    /// total, claim nothing else, and above all do not divide.
    func testNoHonestDenominatorClaimsNothing() {
        var d = DishData.sample
        d.energyWhSinceBoot = 251.9
        d.energyCoversBoot = false
        d.energySeconds = 192
        d.energyAvgW = 0        // the Go side refused to compute one

        let s = line(d)
        XCTAssertEqual(s, "251.9 Wh measured")
        XCTAssertFalse(s.contains("since boot"))
        // No wattage. Checked as "no separator plus trailing W" rather than
        // "no letter W", which `Wh` satisfies trivially.
        XCTAssertFalse(s.contains("·"), "no average may appear: \(s)")
        XCTAssertFalse(s.hasSuffix(" W"), "no average may appear: \(s)")
    }
}

extension MenuBarTests {
    /// The energy total was in the app all along, as the smallest grey text on
    /// the panel under Power — reported as "I don't see it at all". It is a
    /// menu-bar field now, opt-in, so it can be put where it is actually read.
    func testEnergyFieldRendersWholeWattHours() {
        var d = DishData.sample
        d.energyWhSinceBoot = 256.4
        XCTAssertEqual(MenuBarField.energy.text(d), "256Wh")

        // Nothing measured yet is not "0Wh"; it is nothing to say.
        d.energyWhSinceBoot = 0
        XCTAssertNil(MenuBarField.energy.text(d))
    }

    /// Off by default: adding a case to the enum must not silently widen the
    /// menu bar of everyone who already had one configured.
    func testEnergyIsNotOnByDefault() {
        XCTAssertFalse(AppState.defaultFields.contains(.energy))
    }
}

extension EnergyLineTests {
    /// Watt-hours on the Observed line. A dish left up for a month draws past
    /// 20 000 Wh, which is a figure nobody parses at a glance.
    func testWattHourFormatting() {
        XCTAssertEqual(ConnectedPopover.wh(3.42), "3.4 Wh", "below 10 the tenths still say something")
        XCTAssertEqual(ConnectedPopover.wh(53.4), "53 Wh")
        XCTAssertEqual(ConnectedPopover.wh(267.6), "268 Wh")
        XCTAssertEqual(ConnectedPopover.wh(9_999), "9999 Wh")
        XCTAssertEqual(ConnectedPopover.wh(21_400), "21.4 kWh")
    }

    /// The Observed block's energy is its *own* — integrated from the samples
    /// that block describes — and must not be the since-boot accumulator, which
    /// covers a different window. Two different questions on one line would
    /// invite reading either as the other.
    func testObservedEnergyIsNotTheSinceBootTotal() {
        let o = DishData.sample.observed
        XCTAssertNotNil(o)
        XCTAssertEqual(o?.energyWh, 53.2)
        XCTAssertNotEqual(o?.energyWh, DishData.sample.energyWhSinceBoot,
                          "they are separate accumulators over separate windows")
    }
}

extension EnergyLineTests {
    private func cellHelp(_ d: DishData) -> String {
        ConnectedPopover(d: d, showSettings: .constant(false)).energyCellHelpForTesting
    }

    /// Both tooltips exist to answer one question — *used over how long?* — so
    /// each must actually name a duration, and neither may imply the other's
    /// window. Two watt-hour figures a few points apart is the confusion this
    /// text is paying for.
    func testEnergyTooltipNamesItsWindow() {
        var d = DishData.sample
        d.energyWhSinceBoot = 251.9
        d.energyCoversBoot = false
        d.energySeconds = 10_800
        d.energyAvgW = 30.1
        let partial = cellHelp(d)
        XCTAssertTrue(partial.contains("3h"), "must say how long it covers: \(partial)")
        XCTAssertTrue(partial.contains("higher"), "must say the real since-boot figure exceeds it")

        d.energyCoversBoot = true
        XCTAssertTrue(cellHelp(d).contains("since the dish last booted"))

        // No denominator: it must say so rather than invent one.
        d.energyCoversBoot = false
        d.energyAvgW = 0
        let unknown = cellHelp(d)
        XCTAssertTrue(unknown.contains("not known"), unknown)
        XCTAssertFalse(unknown.contains("average is offered."), "no average may be quoted")
    }

    /// The Observed block's own tooltip, which must name that block's window and
    /// point at the other figure so the two are not read as one.
    func testObservedEnergyTooltipDistinguishesItselfFromThePowerCell() {
        let o = try? XCTUnwrap(DishData.sample.observed)
        guard let o else { return XCTFail("sample must carry an observed block") }
        let help = ConnectedPopover(d: .sample, showSettings: .constant(false)).energyHelpForTesting(o)
        XCTAssertTrue(help.contains(ConnectedPopover.dur(o.seconds)), "names the observed window: \(help)")
        XCTAssertTrue(help.contains("since-boot"), "points at the other Wh on screen: \(help)")
    }
}
