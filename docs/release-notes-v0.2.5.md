# v0.2.5 — the energy guard actually holds now

Independent reviews by Codex and Grok both found the same defect in v0.2.1's
fix, and both were right: **the guard expired on a timer.**

## The refusal is persisted, not recomputed

v0.2.1 refused to state an average when the energy total and the sample count
could not both be true. But it refused only at *read* time, while the integrator
kept adding to both halves underneath. The ratio therefore decayed back through
the bound and the refusal lapsed.

Measured on the exact pair it was written for — 251.95 Wh against 192 s — at a
real 30 W draw it re-crosses the bound after **85 minutes**, and the CLI resumes
publishing `est 6242 Wh` against an actual ~936 Wh. The guard delayed the
fabrication rather than preventing it.

An impossible pair is now marked `ObsSecondsUnknown` **once and written back**,
which is the mechanism this codebase already had for exactly this situation.
Once marked it stays marked until the next reboot re-bootstraps both halves
together.

## That also closed a hole the guard never covered

`sl pb` without an anchor extrapolates the bank from `EnergyWh × uptime ÷
ObsSeconds` and never consulted the average at all — 140 kWh "used" from the
same pair, which empties the bank readout. It already returns early on a
non-positive sample count, so persisting the sentinel fixed it without a second
guard. One sentinel, every consumer.

## Smaller, all review findings

- **"dies in 0h 0m"** — zero time-to-empty is the *no honest average* sentinel,
  not an imminent death. Now `runtime unknown · no measured draw`.
- **The CLI's fallback said `over <uptime>`** while explicitly not knowing the
  window. Now `measured · window unknown`, matching the app.
- **The Power cell's fallback could reintroduce the truncated string.** It is
  not cold-start-only: stats can be unready while a long energy epoch exists.
  Shortened.
- **The menu-bar Energy field said "total measured this boot"** — the same claim
  the rest of this work removed. Now "measured total, no window".
- **A zero energy figure is omitted**, not drawn as `0.0 Wh in 2h 14m`. Hardware
  without a power sensor measures nothing; that is not a measurement of zero.
- Stale tooltip copy naming a figure v0.2.4 removed, and the test that pinned it.

## On the threshold itself

Grok's sharpest point stands: a watt ceiling is a physics guess about a
bookkeeping failure, and a High Performance or maritime dish running its heater
could honestly average past it. The ceiling only *detects*; the durable part is
the persisted sentinel. The failure direction is the tolerable one — a false
positive costs the average and degrades to "no claim", a miss states a
fabrication as fact — and the figure is set for the Standard and Mini this
project is tested against. Documented at the constant.
