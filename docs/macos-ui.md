# macOS app — average vs peak, and which window

> Status: **decided, not implemented.** The Go core already emits everything
> below (see “Data contract”); no Swift view has been changed yet.
>
> Decided 2026-08-04 after independent consults with Codex and Grok, which
> agreed on every substantive point. Where they differed, the resolution and
> the reasoning are recorded under [Open points settled](#open-points-settled).

## The problem this fixes

Every summary figure the app showed came from one source: `h.LastN(ring, 60)`,
a 60-second slice of the dish's 15-minute history ring. That includes the ones
labelled `avg` **and** the one labelled `max`. So:

- `downMax` in `ConnectedPopover` was a 60-second maximum presented as a peak.
- `downAvg` in `CompactWidget` was a 60-second mean presented as typical speed.
- Nothing in the app could see past 15 minutes, and everything reset on reboot.

The second one is the dangerous defect. **Mean throughput measures utilization,
not link capability.** An idle dish on a flawless link averages near 0 Mbps, so
`avg 3` reads to a user as a broken dish. The number is correct and the
impression it creates is false.

## The rule

> If a metric reads zero when idle (throughput), show a **peak** over a labelled
> window — never a mean.
> If a metric is **bimodal** (loss on a moving dish), show **event counts** —
> how many, how long, how much of the time — never a mean.
> If a metric is sampled continuously and unimodally (ping, power), show a
> **mean** over a labelled window.
> A metric's *total* is never misleading, even when its mean is — so throughput
> gets **volume transferred** where a mean would lie.
> And only average samples that were actually **measured** — see below.

That last-but-one clause is the escape hatch from the utilization trap. The sum
of a throughput series isn't a rate at all; it's data volume, which is exactly
what a user wants to know and carries no false implication about link quality.

### Why loss gets events, not a mean

Measured on a mobile dish driving through tunnels, over 900 seconds:

| bucket | share |
|---|---|
| clean (drop = 0) | 65.1% |
| fully dark (drop = 100%) | 21.7% |
| anything in between | 13.2% |

That averages to `loss 25.5%` — a figure not one single second experienced. The
distribution has no middle, so its mean names a state that never happened. What
the same window actually contains is **11 outages, longest 58 s, 3m 18s dark**,
which is both true and actionable. `clean %` replaces `loss %` as the headline
because the fraction of usable seconds is what you feel.

Corollary: `worst second` is dead weight on a link like this — it reads 100%
permanently.

### Why ping is gated on drop

The dish reports a plausible-looking latency for **every** second, including
ones where 100% of packets dropped. Measured over the same window: 231 of 231
fully-dark seconds carried a nonzero value, median 19.7 ms. There is no
sentinel, no zero, nothing to filter on — the fabricated values look exactly
like real ones.

So latency is counted only when `drop < 1.0`: if even one packet returned the
measurement is real, and if none did it is invented. Partial loss still counts,
because those packets genuinely made the round trip.

The effect on the headline number is small (24.5 → 23.3 ms) and that is
precisely the hazard — nothing about the polluted mean looked wrong. The tail is
where it showed: dark seconds reached 141 ms and were what pushed p95 to 55 ms.

## Windows

Three horizons, all fixed, each labelled where it appears:

| Layer | Window | Role |
|---|---|---|
| Metric grid | **now** (latest sample) | the live numbers |
| Sparklines | **60 s / 5 m / 15 m**, user-selected | shape, plus a matching trailing figure |
| Session footer | **observed, this dish boot** | honest long-window quality |

### The sparkline window is switchable (reversal, 2026-08-15)

This section previously read *"**No window switcher.** A toggle costs space the
popover doesn't have, makes values incomparable between glances, and would
reintroduce exactly the mean-throughput reading we're removing."* That was
overruled by the user, who asked for ping history explicitly. The three
objections were real, so here is what each one turned into rather than a claim
that they didn't apply:

- **Space.** The picker sits on the existing section-heading row, opposite the
  heading. It costs no vertical space at all.
- **Incomparable between glances.** Conceded, and answered by making the block
  self-describing: the heading states the span the *data* covers on every frame,
  so no glance and no screenshot is ambiguous about which window it is showing.
- **Reintroducing mean throughput.** It does not. The `↓ Mbps` row still carries
  no trailing figure at any window — widening the window changes the trace, not
  what is claimed about it. Only ping and power keep trailings, and both are
  legitimately means at any horizon.

The ceiling is 900 s because that is the depth of the dish's own
`dishGetHistory` ring, not a product choice. Offering more would caption data
that cannot exist.

**The heading names what came back, never what was asked for.** A dish two
minutes past a reboot answers a 900-sample request with 120 samples; `dashboard.go`
therefore emits `seriesSeconds`, and every caption reads that. The failure this
prevents is the same shape as the `max`-as-peak defect at the top of this
document: a correct number under a caption that overstates it.

Two consequences that are easy to get wrong separately and have to agree:

- `seriesSeconds` is `shortestSeries(ping, down, power)` — the shortest **non-empty**
  series among the ones the block draws, not `len(pingSeries)`. `LastN` clamps
  each ring independently, so they are only equal by construction on firmware
  that ships them equal.
- **A row whose series is empty is omitted, not drawn blank.** Excluding an empty
  ring from the figure (so one absent ring cannot hide two good traces) is only
  honest if the absent row is gone too — otherwise firmware with no `powerIn`
  gets a blank power row under a heading claiming to cover it.

The same applies to `sl dash`: `renderSparklines` captions from the samples it
actually plotted, not from `L.SparkW`. Before the ring clamp below, `LastN`
padded a young dish's window with unwritten zeros so the two were always equal
and the distinction did not exist.

**`LastN` clamps on written samples, not on the allocated ring.** The dish always
sends 900 slots and a monotonic-since-boot `current` cursor, so clamping to
`len(ring)` returned unwritten defaults as readings: a flat trace for the
unwritten remainder, means diluted toward zero, and a covered-window figure
overstating the data by exactly that remainder. Invisible on any dish that has
been up a while, which is every dish anyone tests against.

## Per-metric decisions

| Metric | Statistic | Window | Where | Label |
|---|---|---|---|---|
| Ping | mean, measured seconds only | selected spark window | spark trailing | `avg 31 ms` |
| Ping | mean, measured seconds only | observed | footer | `ping 29` |
| Drop | **clean-second share** | observed | footer | `92% clean` |
| Drop | **outage events** | observed | footer | `11 outages · longest 58s` |
| Drop | current | now | grid sub-label | `drop 0.2%` |
| Down | **peak** | observed | footer | `peak ↓186` |
| Up | **peak** | observed | footer | `peak ↑41` |
| Down / Up | **volume** | observed | footer | `4.2 GB ↓ · 0.6 GB ↑` |
| Power | mean, zeros excluded | selected spark window | spark trailing | `avg 24.0 W` |
| Power | mean, zeros excluded | observed | grid sub + footer | `23.8 W session` |

Deliberately absent: any session mean for down or up. The Go DTO does not even
carry the field, so the view cannot accidentally render one.

Ping keeps a mean rather than a max because a maximum surfaces isolated spikes
rather than the experience. Drop gets the opposite treatment — its one-second
maximum is almost always 100% during any brief outage, which is true and
useless — so the mean is the headline and the worst second is detail.

## Exact strings

| Location | String |
|---|---|
| Spark section heading | `Last %@` — the span of the data, from `seriesSeconds` |
| Spark section heading, no ring yet | `No history yet` — not `Last 0s`, which states a measurement of zero duration |
| Battery popover draw heading | `Draw · last %@` — same window control, same `seriesSeconds`; both surfaces plot the same series and must describe it identically |
| A spark row whose series is empty | *(omit the row — see `shortestSeries` below)* |
| Window picker | `60s` `5m` `15m` — 60 s stays in seconds; `1m` beside `5m` and `15m` reads as a broken scale |
| Ping spark row label | `Ping ms` |
| Down spark row label | `↓ Mbps` — never the word "Down", which beside "Ping" reads as *outage* |
| Power spark row label | `Power W` |
| Ping spark trailing | `avg %d ms` |
| Down spark trailing | *(remove — the footer carries the honest peak)* |
| Power spark trailing | `avg %.1f W` |
| Power grid sub-label | `%.1f W session` |
| Session footer | `Observed %@ · ping %d · %d%% clean · peak ↓%d ↑%d · %.1f W` |
| Session footer, second line when outages > 0 | `%d outages · %@ dark · longest %@` |
| Footer, cold start (< 2 min observed) | *hide the row entirely — never show zeros as statistics* |
| Tooltip on the footer | `Covers seconds the dish recorded and DishWatch retrieved, including up to 15 min of catch-up after a gap. Longer gaps are excluded entirely.` |

Use the existing `HumanDur` style for the duration: `12m`, `2h 14m`, `1d 3h`.

## Why the word is “Observed”

Not `Session`, not `Today`, not `Since boot`. **`Observed` is the disclaimer** —
it claims only the seconds we actually hold a sample for, and quietly declines
to claim anything about the rest. That is why no second caveat line is needed
underneath.

**The tooltip is load-bearing, though, and saying otherwise was wishful.** Once
the fold recovers samples from a window the user had the app closed for,
"Observed" is a claim about *sample provenance*, not about app presence — and
ordinary English hears the second one. Someone who quits for ten minutes and
returns to `Observed 2h 14m` will reasonably read it as "while DishWatch was
watching". The catch-up rule is what closes that gap, so it has to be reachable
from the UI rather than living only in this file. Never phrase the row, its
tooltip, or any settings copy as "while the app was running".

Two consequences that must hold or the word becomes a lie:

1. The duration comes from the **sample count**, not `now - obsStartTs`. Wall
   clock would silently absorb every gap into the denominator.
2. Every counted second must correspond to a sample the dish actually recorded
   and we actually retrieved. Nothing is interpolated, estimated, or projected
   across a gap.

**Observed is not the same as "while the app was frontmost", and deliberately
so.** Each poll folds forward every ring sample since the previous cursor, which
is the only reason a 15-second poll cadence can describe fifteen seconds of link
quality rather than one — and Phase 4 of the roadmap widens that cadence to
5–15 s idle precisely to save battery. Clamping the fold to samples postdating
`LastTs` would thin the statistics in exact proportion to how cheap we make
polling, which is backwards.

The honest limit is therefore the dish's buffer, not the app's lifetime: a gap
up to the 15-minute ring is recovered in full, and a gap wider than the ring
contributes **nothing** — not even the portion still sitting in the buffer, and
that under-claim is intentional. Consequence #2 still holds throughout, because
folded samples are real recorded seconds; the tooltip is what had to change.
`integratestats_test.go` pins all three halves of this envelope: the fold, the
drop, and — because a run in progress must not be welded across a hole we never
measured — the outage that gets closed when the gap is dropped.

## Files to change

| File | Change |
|---|---|
| `Model/DishData.swift` | **done** — the block decodes as one optional `ObservedStats`, all-or-nothing. Emphatically *not* "resiliently like the rest": per-key fallbacks would render `peak ↓0 · 0 W` from a payload missing one key, under the word that carries the honesty claim. `nil` → hide the row |
| `Views/ConnectedPopover.swift:89-91` | **done** — spark block heading now names the covered span; Down trailing dropped; ping/power trailings kept; row labels carry their units |
| `Views/ConnectedPopover.swift` | add the session footer row below the sparklines |
| `Views/CompactWidget.swift:58-59` | replace `avg \(Int(d.downAvg))` / `avg \(Int(d.upAvg))` with `peak` from the session fields |
| `Views/BatteryPopover.swift:102` | leave `Wh` alone — the runtime estimate depends on accumulated energy; the watts figure belongs elsewhere |

## Data contract

`dishwatch json` already emits these (see `dashboard.go`), sourced from
`~/.cache/sl/stats.json`. All are zero when fewer than 120 samples have been
collected, which is the app's cue to hide the footer.

| Field | Meaning |
|---|---|
| `seriesSeconds` | samples the sparkline series actually carry — **not** the window requested; see the reversal note under *Windows* |
| `obsSeconds` | samples actually integrated this boot |
| `obsCoverage` | `obsSeconds ÷ uptime`, 0..1 |
| `sessPingAvg` | ms, seconds with a returned packet only |
| `sessDropAvg` | percent — retained for completeness; **do not display**, see above |
| `sessCleanPct` | share of seconds with zero loss |
| `sessOutages` | count, including one in progress |
| `sessOutageSeconds` | total seconds at ≥90% loss |
| `sessLongestOutage` | seconds, including a run in progress |
| `sessDownPeak` / `sessUpPeak` | Mbps |
| `sessDownBytes` / `sessUpBytes` | bytes transferred |
| `sessPowerAvg` / `sessPowerPeak` | watts |

## Open points settled

**Anchor: dish boot or observation start?** Codex proposed heading the block
`THIS DISH BOOT · 2h 14m observed`; Grok proposed `Observed 2h 14m` anchored to
when observation began. Resolved in favour of Grok's *word* and Codex's *epoch*:
the accumulator resets on reboot (the dish's own counters restart, so averaging
across the discontinuity would blend two different link sessions), but the label
leads with `Observed` because that is the claim we can actually defend.

**How many horizons on screen?** Grok kept 60-second trailings on every
sparkline plus a session footer; Codex stripped all trailings so exactly one
summary window exists. Resolved between them: keep trailings only where they
cannot be misread as capability (`avg 31 ms`, `avg 24.0 W`) and drop the Down
trailing entirely. The sparkline already shows the shape; the footer carries the
peak that means something.

**Replace `Wh since boot` with session watts in the power cell?** Grok suggested
it; rejected. `BatteryPopover`'s runtime estimate is derived from accumulated
Wh, so the energy total earns its place in the battery UI. Session watts go in
the grid sub-label and footer instead.

## The menu-bar readout

The status item draws a **glyph** and a **readout**. They are independent
settings, which is the change: "Data readout" used to be an `IconMode`, so the
only way to get a number into the bar was to give up the glyph, and the only
number available was ping.

| Setting | Values |
|---|---|
| Glyph | Signal bars · Dish arc · Auto (battery on bank, else signal) · No glyph |
| Readout | any subset of: Ping graph, Ping, Download, Upload, Signal score, Power draw, Battery % |

Rules that are load-bearing rather than cosmetic:

- **Render order is `MenuBarField.allCases`, not tick order.** The bar must not
  reshuffle itself when a box is toggled, and its width must be predictable from
  the settings screen.
- **A field with nothing to say draws nothing.** Battery % off a power bank
  contributes no text and no separator — not `0%`, which reads as a flat
  battery rather than as "not on one". This is the same rule as hiding the
  Observed footer under 120 samples.
- **Throughput is unit-less, with one decimal below 10 Mbps and whole Mbps
  above.** The arrow says the direction. The split is not cosmetic: rounding
  everything to `Int` rendered an idle-but-healthy dish doing 0.3 ↓ / 0.4 ↑ as
  `↓0 ↑0`, which states that nothing is flowing — the same misreading this
  document already records for mean throughput. Past 10 Mbps the tenths carry no
  such meaning and the menu bar is where two glyphs of width is a real cost.
  Rounding happens before the format is chosen, so 9.96 is `10`, never `10.0`.
- **An empty readout with no glyph falls back to the signal bars.** Otherwise
  the status item is zero-width — invisible, with nothing left to click to reach
  Settings and undo it. The only unrecoverable configuration is the one the UI
  refuses to produce.
- **The tooltip carries every headline number**, whichever ones the user left
  out of the bar.

### The ping graph costs a redraw per poll

`MenuBarLabel` caches its rasterised glyph against the handful of inputs it
actually depends on, because re-rendering a SwiftUI view on the main actor once
a second was the app's dominant idle cost. A live sparkline reopens that by
definition: its shape *is* the data. So it is opt-in, labelled *"redraws every
poll"* in Settings, and its cache key is the last 26 ping samples quantised to
whole milliseconds — finer than a 12 pt-tall trace can express, and enough to
keep a flat link from re-rendering at all.

It is drawn with `Canvas` and a bare stroke rather than reusing `Spark`, whose
gradient fill flattens to a grey haze once the image becomes a template mask.

### Settings preview

The readout is the one setting whose result is invisible while you choose it —
the panel is covering the menu bar it changes. The preview row therefore renders
`MenuBarIconContent` itself, with the ink colour swapped for the dark panel, so
it cannot drift from what the bar actually draws.

### Migration

Pre-field preferences map exactly, and only a genuinely new install (no
`iconMode` ever written) gets the default set. Anything else silently
redecorates a menu bar the user had already configured.

| Stored | Becomes |
|---|---|
| `iconMode = Data readout` | glyph `No glyph` + readout `[Ping]` |
| `showValue = true` | readout `[Signal score]`, glyph unchanged |
| `showValue = false` | readout `[]`, glyph unchanged |
| *either* legacy key, no `menuBarFields` | migrate as above, then **persist** |
| neither legacy key | glyph `Signal bars` + readout `[Ping, Download, Upload, Battery %]`, then **persist** |

**"Upgrade" is any domain carrying either legacy key, and every resolution is
written back.** Both halves are load-bearing, and each was wrong once:

- Keying only on `iconMode` misread a user who turned *Show value* off and never
  opened the glyph picker — both keys were written solely by their own `didSet`,
  so `showValue` alone is an ordinary state.
- Returning the fresh-install default *without persisting it* was worse, because
  `init` assignments do not fire `didSet` in Swift: nothing was written, and the
  first tap on the glyph picker then produced `{iconMode, no fields}` — shaped
  exactly like a pre-fields upgrade. The next launch read the absent `showValue`
  as its old default of `true` and collapsed the four-field readout to the signal
  score. Reachable on a new install by tapping the glyph already selected.

## Precedent for the CLI

The same rules are already live in `sl dash` — `renderSparklines` for the 60 s
window and `renderObserved` for the session block. Keep the two surfaces
consistent; if a statistic is wrong to show in one, it is wrong in the other.
