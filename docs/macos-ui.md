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
- **Reintroducing mean throughput.** It does not. The `↓↑ Mbps` row still carries
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
| Down / Up | mean, idle seconds included | selected spark window | spark trailing | `avg ↓12.4 ↑1.4` |
| Down / Up | **volume** | observed | footer | `4.2 GB ↓ · 0.6 GB ↑` |
| Power | mean, zeros excluded | selected spark window | spark trailing | `avg 24.0 W` |
| Power | mean, zeros excluded | observed | grid sub + footer | `23.8 W session` |
| Down / Up | **the sample under the pointer** | one second | spark trailing, while scrubbing | `↓143 ↑14` |

Deliberately absent: any session mean for down or up. The Go DTO does not even
carry the field, so the view cannot accidentally render one.

### The ↓↑ spark trailing shows a mean (2026-08-17)

That slot was empty until now, on the grounds that the only statistic on offer
for it was a mean and a mean there would lie. Both halves were right and the
conclusion still did not follow: with `avg 49 ms` beside ping and `avg 46.4 W`
beside power and nothing beside throughput, the question the panel raises is
*why is this row missing its figure* — which the emptiness cannot answer.

It now shows `avg ↓12.4 ↑1.4`, one figure per direction over the plotted window.
This is a deliberate narrowing of the rule above, not an exception to it. What
makes a lone `avg 3` dangerous is that it is *alone*: a summary cell offers a
mean and nothing else, so a reader takes it for what the link can do. In this
row the mean has company — the trace it summarizes is immediately to its left,
so the shape it flattens is on screen; the peak that does describe capability is
in the Observed footer two blocks down; and the heading names the window it
covers. The rule stands everywhere a throughput mean would appear without those
three, which is every summary figure the app shows.

Computed from the traces the row actually drew (`Spark.mean`), not from
`downAvg`/`upAvg` on the DTO. Those carry the same numbers, but reading the
traces keeps the figure tied to what is on screen: it follows the 60s/5m/15m
buttons for free, and a direction whose ring the dish never sent contributes no
number rather than a fabricated `↑0.0`.

Idle seconds are included, unlike ping (`nonzeroMean`) and power
(`meanPositive`), where a zero means *not measured*. A second in which no data
moved is a real second of the window; excluding those would answer "how fast
while busy", which nobody asked and which flatters a bad link.

Scrubbing still overrides it with the sample under the pointer, as before — the
`avg` word is what distinguishes the two readouts, since both are `↓n ↑n`.
`Spark.mean` skips non-finite values for a sharper reason than `sample` does:
one infinity in the sum takes the entire average with it.

### Download and upload share one chart (2026-08-15)

Upload had no trace at all — the block plotted ping, download and power, and the
`↑` number appeared only in the grid cell and the Observed peaks. It is one row
with two traces rather than a fourth row, and two rules make that honest:

- **One vertical range across both, floored at zero.** Auto-ranging each trace
  to itself would draw a 14 Mbps upload at the same height as a 143 Mbps
  download: two correct lines composing a false picture, which is the defect at
  the top of this document wearing a different hat. Sharing a `min..max` range
  is not enough either — a download and upload that happen to sit close together
  become two full-height traces of noise, which is utilization drawn as
  amplitude. Throughput has a true zero, so this row alone uses `0..max`; ping
  and power keep auto-ranging, because for them the variation *is* the news.
- **Download keeps the gradient; upload is a line.** A low trace inside another
  trace's fill dissolves into it, which is how a real 14 Mbps upload comes to
  read as no upload at all.

The ink is fixed, not a setting, and these are the numbers:

| Trace | Colour | Weight |
|---|---|---|
| ↓ download | `0x4B8DF8` | 1.4 pt line + fill at 50% |
| ↑ upload | `0x9B90D9` | 1.5 pt line at 85%, no fill |

Both were louder once and both were wrong for the same reason. Upload's first
violet (`0xA78BFA`) at full strength on a 1.7 pt stroke made the *quieter* of
the two directions draw the heaviest ink in the block, on a panel whose entire
palette is otherwise muted — beside cyan ping and amber power it read as an
alert. The hue is what separates the directions, so the hue stayed and the
chroma went; the download fill is what carries the pair, so the line above it
does not also have to shout.

**Offered as a Settings slider and declined, 2026-08-15.** An opacity control
is a knob whose main job is undoing a bad default, and the fix for a bad
default is a better default. Per-direction opacity would additionally make
reachable exactly the two states this row is designed to prevent: an upload so
faint it reads as absent, and a pair loud enough to be unreadable where they
cross.

The cost is real and accepted: while download is an order of magnitude larger,
upload sits near the floor and shows proportion rather than shape. **Scrubbing
does not undo that** — it reads back a value at a second you already chose, not
a wiggle the eye never saw. What the shared axis buys instead is the reading the
row exists for: download collapsing toward upload is a distance on screen.
Upload's own shape is a different question, and if it becomes a requirement it
costs a second row, not a second scale the canvas cannot announce.
- **Right-aligned, never stretched.** `LastN` clamps each ring independently, so
  the two series can arrive with different lengths. Both end at *now* on the
  right and a shorter one starts further in. Stretching it across the full width
  would relabel every one of its samples as older than it is — `seriesSeconds`
  already refuses to make that claim in the heading, and the drawing must not
  make it either.

A trace whose series is empty is dropped from the row and the legend drops its
arrow with it; a row left with no traces is omitted entirely, as before.

Colour is now load-bearing, so `DW.up` moved from `0x6FA8FF` to violet
`0xA78BFA`. It was four points of hue from `DW.down`, which was survivable while
the two only ever appeared in separate cells and is not survivable on one axis.
The Upload grid cell's bar was drawing in the *download* blue; it now matches.

**Colour alone was still not enough (2026-08-15).** Two hues separate the traces
only while the row is at its easy shape — download an order of magnitude above
upload. At the shape a roaming dish actually spends its day in, both directions
a few Mbps and crossing a dozen times across 24 points of height, "the blue one"
and "the violet one" become a colour-matching exercise, and that is before
anyone who cannot separate the hues at all. So the pair differs in **kind**, not
only in hue:

- **Download is an area**, at a heavier fill than a lone trace carries
  (`fillOpacity: 0.5` against the 0.33 default).
- **Upload is a bare line**, unfilled and a little thicker (1.7) to pay for the
  fill it does not have. A low trace *inside* another trace's fill dissolves
  into it, which is how a real 14 Mbps upload comes to read as no upload.

The harness renders both shapes — `connected.png` for the easy one, `tangled.png`
for the crossing one — because a change to that fill weight looks free against
the easy shot alone.

### Which dish this is, and who aims it

The header carries a drawn dish, the model, and whether the panel aims itself:
`🛰 Standard Gen2 · ⚙︎ Self-aiming`.

The aim half is the whole reason it exists. `hardwareShort` was the only thing
the app ever said about the hardware and it said **"Standard"** for both a Gen2
and a Gen3 — the two units that differ on precisely this question, one aiming
itself and the other aimed by hand and never moved again. Nothing else on any
screen answered it, and the CLI did not either.

- **The generation is in the name** now (`Standard Gen2`, `Standard Gen3`,
  `Round Gen1`, `Mini`, `High Performance`), because a label that cannot
  distinguish the two is the same defect as a number without its window.
- **Aim is inferred from the model, and the inference is stated in one place.**
  The dish will not answer directly: `dish_get_context`, which carries the
  actuator flag, is `PermissionDenied` to an unauthenticated caller and
  `get_status` has no such field. `classifyHardware` in dashboard.go is where
  "rev3 is a Gen2, and a Gen2 has motors" is written down for both surfaces.
- **An unplaceable model says nothing.** It keeps its raw string and the aim
  clause is dropped entirely rather than guessed. Telling someone with a
  motorized dish to go turn it by hand is the one failure here with a cost
  outside the screen.
- **It sits in the header, not the hero.** The hero's lines are about this
  session — uptime, boots, firmware — and the hardware is the one fact that
  never changes between polls. The run between the app name and the clock was
  the only place with room for a picture.
- **The picture is drawn, not shipped.** SpaceX's product renders and the
  Starlink marks are theirs; a Store submission is the wrong place to carry
  someone else's product photography. `DishGlyph` is one silhouette — a flat
  panel on a stem — which is a true outline of the Mini and both Standards
  alike, since they differ in size rather than in shape. The generation is
  written beside it in words rather than mimed in geometry.

### Scrubbing a sparkline

Press and drag along any trace: a rule marks the column, a dot lands on each
trace that has a sample there, the trailing figure becomes the value under the
pointer, and the heading becomes its age. Release clears it.

- **It is a press, not a hover.** Hover tracking and `.help` both fail in this
  non-activating panel — see *Tooltips are not a place to put information*. A
  click is the one thing the panel is known to receive.
- **The marker is cleared on release rather than pinned.** The series shift left
  every poll, so a marker that outlived the gesture would sit on a different
  second a second later while still captioned with the old age.
- **A scrubbed figure is a sample, not a statistic**, which is the only reason
  the `↓↑` row may show one at all. Its idle trailing stays empty: a mean there
  reads as capability, and naming one second of the trace claims nothing of the
  sort.
- **Ages come from the column, not from a clock.** The dish records one sample
  per second, so a column distance *is* an age in seconds.

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
| Spark section heading, while a row is scrubbed | `%@ ago` from the marked column, or `now` at the newest sample |
| Ping spark row label | `Ping ms` |
| Throughput spark row label | `↓↑ Mbps` — never the word "Down", which beside "Ping" reads as *outage*. The arrows carry the trace colours and are the chart's only legend, so they are built from the traces actually drawn |
| Power spark row label | `Power W` |
| Ping spark trailing | `avg %d ms` |
| Throughput spark trailing | *(empty — the footer carries the honest peak)* |
| Power spark trailing | `avg %.1f W` |
| Any spark trailing, while that row is scrubbed | the sample under the pointer in the row's unit: `31 ms`, `23.4 W`, `↓143 ↑14` — each throughput figure in its trace's colour |
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
| `hardwareShort` | model with its generation — `Standard Gen2`, `Mini`, or the raw string when unplaceable |
| `hardwareAim` | `motorized`, `manual`, or `""` — inferred from the model, since the dish will not say; `""` renders as nothing |
| `metered` | `true` when the dish reports `treatAsMetered`. The wire omits the field when false, so `false` also means "firmware too old to say" — the panel may state that a link **is** capped, never that one is not. The dish never reports how much allowance remains, so no view may imply a budget |
| `serviceDisable` | why service stopped, normalized off `UtDisablementCode` — `inOcean`, `roamRestricted`, `dataOverage`, `movingTooFast`, `noAccount`, … or `""`. Present exactly when `state` is `Disabled`; it says the thing `state` cannot, since a dish blocked over open ocean and one blocked for an unpaid bill read identically without it. An unrecognized code maps to `""`: the outage still shows, only its reason goes unstated |
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

## Tooltips are not a place to put information

`.help()` does not reliably fire inside the `MenuBarExtra(.window)` panel. It is
non-activating, so AppKit's tooltip tracking mostly does not run, and a hover
produces nothing. Found the way these things are always found — "hovering over
115wh doesnt explain anything" — after two figures were given careful
explanatory tooltips that no user could ever have seen.

Consequences, in order of importance:

- **Anything a reader needs must be visible.** The Observed block's energy
  states its own window inline (`⚡ 53 Wh in 2h 14m`) rather than relying on the
  heading above it or on a hover. The heading does scope the block, but twice
  that was not the connection a reader made, and one short phrase costs less
  than needing them to.
- The `.help` calls that remain are a bonus for wherever the platform does
  deliver them, never the only copy of a fact. The one on the Observed block
  that this document calls load-bearing has, on that evidence, probably never
  rendered.
- Tooltips on `Button`s — *Unpin*, *Settings & quit* — and on the status item
  itself do work; those are AppKit controls with their own tracking areas.

## Two energy figures became one

The Power cell carried an energy total for two releases and should not have.
The cell answers *watts now*; it is half a popover wide, so the honest
three-case energy string overflowed it and shipped truncated as
`115.1 Wh over 3h 44m · 30....`; and once the Observed block grew its own energy
figure the two sat a few points apart showing near-identical numbers over subtly
different windows.

The second number was the problem, so it is gone. The cell shows `peak %.1f W`
from the session — a fact nothing else on screen states — and falls back to the
energy line only at cold start, before there is an Observed block to carry it.

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

### The bar must not quote a reading it does not have (2026-08-15)

An unreachable dish is not a failed poll. `offlineDashboard` restores the last
snapshot's ping and leaves throughput at zero, and the helper returns it as a
*success* — so the popover dimmed itself and said "no dish at this address"
while the bar beside it read `31ms ↓0.0 ↑0.0`. Both halves were false in
different directions: a stale ping presented as current, and a zero presented as
a measurement of an idle link. A failing poll (`.stale`) is worse still, because
the frozen snapshot keeps the signal score too and the glyph stayed at four lit
bars over a dead link.

The popover does not need this rule — it dims and desaturates the whole panel
and its footer says why. The bar is a template image with room for neither, so
its own numbers have to carry it.

| State | Bar shows |
|---|---|
| Ping / Download / Upload / Signal / Power | `—`, `↓—`, `↑—` — the arrows stay so the bar keeps its shape and the dashes keep their identity |
| Ping graph | a dashed midline — blank reads as a rendering fault, the last trace reads as a live link |
| Signal bars / dish arc glyph | drawn at zero |
| Energy, Battery % | **unchanged** — a running total does not become false when the dish stops answering, it stops growing. Energy is watt-hours already measured; the bank percentage comes from the CLI's own anchor |

The gate is `Quality.showsLiveReadings`, which is **not** `isTrustworthy`. The
difference is `.sample`: fabricated data is wrong about the world but internally
current, and the render harness and design demo exist to look at it. `.loading`
is on the dashed side — the neutral decode defaults would otherwise render a
first frame of `0ms ↓0.0 ↑0.0`.

Dashes rather than dropping the fields: dropping them reflows the bar on every
outage, and a bar configured with nothing else would collapse to zero width,
which is the one unrecoverable state this document already forbids.

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
