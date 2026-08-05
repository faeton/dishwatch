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
| Sparklines | **last 60 s** | shape, plus a matching trailing figure |
| Session footer | **observed, this dish boot** | honest long-window quality |

**No window switcher.** A toggle costs space the popover doesn't have, makes
values incomparable between glances, and would reintroduce exactly the
mean-throughput reading we're removing.

## Per-metric decisions

| Metric | Statistic | Window | Where | Label |
|---|---|---|---|---|
| Ping | mean, measured seconds only | last 60 s | spark trailing | `avg 31 ms` |
| Ping | mean, measured seconds only | observed | footer | `ping 29` |
| Drop | **clean-second share** | observed | footer | `92% clean` |
| Drop | **outage events** | observed | footer | `11 outages · longest 58s` |
| Drop | current | now | grid sub-label | `drop 0.2%` |
| Down | **peak** | observed | footer | `peak ↓186` |
| Up | **peak** | observed | footer | `peak ↑41` |
| Down / Up | **volume** | observed | footer | `4.2 GB ↓ · 0.6 GB ↑` |
| Power | mean, zeros excluded | last 60 s | spark trailing | `avg 24.0 W` |
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
| Spark section heading | `Last 60 s` |
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
underneath, and why the tooltip is optional rather than load-bearing.

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
`sessionstats_test.go` pins both halves of this envelope.

## Files to change

| File | Change |
|---|---|
| `Model/DishData.swift` | add the `obs*` / `sess*` fields + `CodingKeys` entries; they decode resiliently like the rest |
| `Views/ConnectedPopover.swift:89-91` | retitle the spark block `Last 60 s`; drop the Down trailing; keep ping/power trailings |
| `Views/ConnectedPopover.swift` | add the session footer row below the sparklines |
| `Views/CompactWidget.swift:58-59` | replace `avg \(Int(d.downAvg))` / `avg \(Int(d.upAvg))` with `peak` from the session fields |
| `Views/BatteryPopover.swift:102` | leave `Wh` alone — the runtime estimate depends on accumulated energy; the watts figure belongs elsewhere |

## Data contract

`dishwatch json` already emits these (see `dashboard.go`), sourced from
`~/.cache/sl/stats.json`. All are zero when fewer than 120 samples have been
collected, which is the app's cue to hide the footer.

| Field | Meaning |
|---|---|
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

## Precedent for the CLI

The same rules are already live in `sl dash` — `renderSparklines` for the 60 s
window and `renderObserved` for the session block. Keep the two surfaces
consistent; if a statistic is wrong to show in one, it is wrong in the other.
