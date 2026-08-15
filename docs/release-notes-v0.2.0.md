# v0.2.0 — you choose what the menu bar shows

The menu bar stops being one number you didn't pick, and the sparklines stop
being stuck at 60 seconds. Plus a latency bug that made every young dish lie
about its own history.

```
brew install --cask faeton/tap/dishwatch-app   # the app
brew install faeton/tap/dishwatch              # the CLI
```

## Pick what sits in your menu bar

The status item used to show one value chosen for you — the signal score — and
the only way to get anything else there was "Data readout", which replaced the
glyph entirely and could only ever show ping.

Now the glyph and the numbers are separate settings. Tick whichever of these you
want, in any combination:

**Ping graph · Ping · Download · Upload · Signal score · Power draw · Battery %**

```
▮▮▮ ∿∿∿ 31ms ↓143 ↑14
```

They always render in the same order regardless of the order you tick them, so
the bar never reshuffles itself. Battery % draws nothing at all while you are on
mains — not `0%`, which would read as a flat battery rather than as "not on
one". And an empty readout with no glyph falls back to the signal bars, because
a zero-width status item is one you cannot click to undo it.

Settings previews the real thing, live, using the same view the menu bar draws.

**Your existing setup carries over exactly.** Signal bars with the score stays
signal bars with the score; a bare glyph stays bare; "Data readout" becomes no
glyph plus ping.

### The ping graph is opt-in on purpose

It redraws every poll, because its shape *is* the data — that is the idle cost
the glyph cache exists to avoid. Settings says so on the row. Everything else in
the bar is cached and costs nothing while the numbers hold still.

Sub-millisecond jitter is drawn flat. A link sitting at 10.1–10.4 ms would
otherwise auto-range into a full-height sawtooth and read as a problem.

## 60 s / 5 m / 15 m of history

The popover's sparklines had a fixed 60-second window. There is now a picker on
the block, and the battery screen's power trace gets the same one.

15 minutes is the ceiling because that is how deep the dish's own history ring
goes — 900 samples, one per second. It is not a product decision and there is no
point offering more.

The heading always names **the span the data actually covers**, never the one you
asked for. Two minutes after a reboot the dish only has two minutes to give, and
it says `Last 2m`.

The CLI gained the same reach:

```
sl json --window 900     # 15 min of sparkline series instead of 60 s
```

## The fix that matters most

**A dish that had recently rebooted invented its own history.**

The dish always sends a full 900-slot ring plus a cursor saying how much of it it
has actually written. We clamped reads to the size of the ring rather than to
that cursor, so a dish two minutes past a reboot handed back 780 never-written
slots as though they were readings.

The damage: sparklines flat for thirteen minutes and then abruptly real, average
throughput diluted toward zero by hundreds of fake zero samples, and — once the
window became selectable — a caption claiming fifteen minutes of data over two
minutes of it.

This was always wrong. At a fixed 60-second window it only affected the first
minute after a reboot, which is easy to never notice; widening the window to
fifteen minutes turned a one-minute blind spot into a quarter-hour one. It is
invisible on any dish that has been up a while, which is every dish anyone
normally looks at.

`sl dash` was affected identically and is fixed with it.

## Smaller things

**Throughput reads `↓0.3 ↑0.4`, not `↓0 ↑0`.** Whole-Mbps rounding turned an
idle-but-perfectly-healthy link into a bar that said nothing was flowing. Below
10 Mbps you get one decimal; above it, the tenths are not worth the width.

**"Down" is gone from the 60-second block.** It meant *download throughput*, but
sitting next to "Ping" in a column about link health it read as *outage*. The
rows are `Ping ms`, `↓ Mbps` and `Power W` now — units, not words with two
meanings.

**A row whose data the dish did not send is omitted rather than drawn blank.**

## Under the hood

The helper protocol is now 3, and `make app` refuses to assemble a bundle whose
embedded helper disagrees with the app about it. That guard exists because this
release shipped exactly that mistake in development: a day-old helper speaking
protocol 2 to an app expecting 3, which the app correctly refused — and, since it
treats a version mismatch as permanent, backed off silently and showed a menu bar
reading `0` with the diagnostics going to `/dev/null`.

The dashboard JSON contract is unchanged at schema v1; `seriesSeconds` is a new
additive field.

## Upgrading

Nothing to do. Settings carry over, the on-disk state format is unchanged, and
the CLI and app can still be run interchangeably against the same
`~/.cache/sl/`.
